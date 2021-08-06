%% @doc Entry point to Logflare API
-module(logflare).

-behaviour(gen_batch_server).
%% gen_batch_server callbacks
-export([init/1, handle_batch/2]).

%% Server startup
-export([start_link/0, start_link/1, start_link/2]).

%% Main API
-export([async/2, async_batch/2, sync/2, sync/3]).

%% Default option values

-define(MIN_BATCH_SIZE, 16).
-define(MAX_BATCH_SIZE, 64).

-type dependency() :: module() | {module(), term()}.

-spec apply_dependency(dependency(), atom(), [term()]) -> term().

apply_dependency({Module, Arg}, Function, Args) ->
    apply(Module, Function, [Arg|Args]);
apply_dependency(Module, Function, Args) ->
    apply(Module, Function, Args).

-record(config, {
                 base_url = <<"https://api.logflare.app">> :: uri_string:uri_string(),
                 path = <<"/logs/erlang/logger">> :: iolist() | binary(),
                 api_key = <<"">> :: iolist() | binary(),
                 source_id = <<"logflare">> :: iolist() | binary(),
                 gun_opts = #{ http_opts => #{ keepalive => 10000 }} :: gun:opts(),
                 ordered = true :: boolean(),
                 min_batch_size = ?MIN_BATCH_SIZE :: non_neg_integer(),
                 low_batch_size_timeout = 0 :: non_neg_integer(),
                 clock = erlang :: dependency(),
                 gun = gun :: dependency()
}).

-type opt() :: {base_url, uri_string:uri_string()} |
               {path, iolist() | binary()} |
               {api_key, iolist() | binary()} |
               {source_id, iolist() | binary()} |
               {gun_opts, gun:opts()} |
               {ordered, boolean()} |
               {min_batch_size, non_neg_integer()} |
               {max_batch_size, non_neg_integer()} |
               {low_batch_size_timeout, non_neg_integer()} |
               {clock, dependency()} |
               {gun, dependency()}.

-type name() :: {local, atom()} |
                {global, term()} |
                {via, atom(), term()} |
                undefined.

%% @doc Starts a logflare server
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link([]).

%% @doc Starts a logflare server
-spec start_link([opt()] | name()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_list(Opts) ->
    gen:start(gen_batch_server, link, ?MODULE, {prepare_gb_opts(Opts), prepare_config(Opts)}, []);

%% @doc Starts a logflare server
start_link(Name) ->
    start_link(Name, []).

%% @doc Starts a logflare server
-spec start_link(name(), [opt()]) -> {ok, pid()} | {error, term()}.
start_link(Name, Opts) ->
    gen_batch_server:start_link(Name, ?MODULE, prepare_config(Opts), prepare_gb_opts(Opts)).

-spec prepare_config([opt()]) -> #config{}.
prepare_config(Opts) ->
    Config = #config{},
    Config#config {
      base_url = proplists:get_value(base_url, Opts, Config#config.base_url),
      path = proplists:get_value(path, Opts, Config#config.path),
      api_key = proplists:get_value(api_key, Opts, Config#config.api_key),
      source_id = proplists:get_value(source_id, Opts, Config#config.source_id),
      ordered = proplists:get_value(ordered, Opts, Config#config.ordered),
      min_batch_size = proplists:get_value(min_batch_size, Opts, Config#config.min_batch_size),
      low_batch_size_timeout = proplists:get_value(low_batch_size_timeout, Opts, Config#config.low_batch_size_timeout),
      gun_opts = maps:merge(Config#config.gun_opts, proplists:get_value(gun_opts, Opts, Config#config.gun_opts)),
      clock = proplists:get_value(clock, Opts, Config#config.clock),
      gun = proplists:get_value(gun, Opts, Config#config.gun)
     }.

-spec prepare_gb_opts([opt()]) -> list().
%% Prepares gen_batch_server options based on options given to logflare:start_link/{0,1,2}
prepare_gb_opts(Opts) ->
    MaxBatchSize = proplists:get_value(max_batch_size, Opts,
                                       ?MAX_BATCH_SIZE),
    MinBatchSize = proplists:get_value(min_batch_size, Opts,
                                       ?MIN_BATCH_SIZE),
    [{max_batch_size, MaxBatchSize},
     {min_batch_size, MinBatchSize}].

%% @doc Sends a log message and immediately returns
%%
%% This won't guarantee that the message will reach the server
-spec async(gen_batch_server:server_ref(), term()) -> ok.
async(ServerRef, Log) ->
    gen_batch_server:cast(ServerRef, {log, Log}).

%% @doc Sends a batch of log messages and immediately returns
%%
%% This won't guarantee that the messagse will reach the server
-spec async_batch(gen_batch_server:server_ref(), [term()]) -> ok.
async_batch(ServerRef, Logs) ->
    gen_batch_server:cast_batch(ServerRef, lists:map(fun (Log) -> {log, Log} end, Logs)).

%% @doc Sends a log message and waits until the batch it is in, is posted
%%
%% Will timeout after 5000 milliseconds.
-spec sync(gen_batch_server:server_ref(), term()) -> ok.
sync(ServerRef, Log) ->
    gen_batch_server:call(ServerRef, {log, Log}).

%% @doc Sends a log message and waits until the batch it is in, is posted
%%
%% This version allows to specify a custom timeout.
-spec sync(gen_batch_server:server_ref(), term(), timeout()) -> ok.
sync(ServerRef, Log, Timeout) ->
    gen_batch_server:call(ServerRef, {log, Log}, Timeout).


-record(state, {
                config :: #config{},
                conn :: undefined | pid(),
                post_in_flight = none :: gun:stream_ref() | none,
                queue = [] :: [map()],
                queued_sync_requests = [] :: [gen_batch_server:from()],
                response_body = [] :: iolist(),
                response_status = undefined :: pos_integer() | undefined,
                timeout_from = undefined :: undefined | non_neg_integer()
               }).


%% @private
-spec init(#config{}) -> {ok, #state{}} | {stop, {error, term()}} | {ok, #state{}, {continue, term()}}.
init(Config) ->
    State0 = #state {
                config = Config
               },
    Gun = Config#config.gun,
    URI = uri_string:parse(Config#config.base_url),
    Scheme = iolist_to_binary(maps:get(scheme, URI, <<"https">>)),
    Host = maps:get(host, URI),
    Port = maps:get(port, URI, port(Scheme)),
    case apply_dependency(Gun,open, [binary_to_list(iolist_to_binary(Host)), Port, Config#config.gun_opts]) of
        {error, Error} -> {stop, {error, Error}};
        {ok, Conn} ->
            %% Here we ensure we can actually establish a connect
            %% before signalling a successful start of this server
            case apply_dependency(Gun, await_up, [Conn]) of
                {error, Error} -> {stop, Error};
                {ok, _Protocol} ->
                    {ok, State0#state {
                           conn = Conn
                          }}
            end
    end.

-spec port(iolist() | binary()) -> inet:port_number().
port(<<"https">>) ->
    443;
port(<<"http">>) ->
    80.

%% @private
-spec handle_batch([gen_batch_server:op()], #state{}) ->
          {ok, #state{}} |
          {ok, #state{}, {continue, term()}} |
          {ok, [gen_batch_server:action()], #state{}} |
          {ok, [gen_batch_server:action()], #state{}, {continue, term()}} |
          {stop, Reason :: term()}.

handle_batch([], State) ->
    {ok, State};
handle_batch(Ops, #state { conn = Conn, post_in_flight = Stream,
                           config = #config { clock = Clock } } = State) ->
    % From every eligible operation, construct an action (if necessary)
    % and add a log to the batch
    {Actions, Batch, State1} = lists:foldl(fun
                                               ({cast, {log, Log}}, {Actions, Batch, AState}) -> % async
                                                   {Actions, [prepare_log(Log)|Batch], AState};
                                               ({call, From, {log, Log}},
                                                {Actions, Batch,
                                                 #state { queued_sync_requests = Queue} = AState}) -> % sync
                                                   {Actions, [prepare_log(Log)|Batch],
                                                    AState#state {
                                                      queued_sync_requests = [From|Queue]
                                                     }};
                                               % Response body
                                               ({info, {gun_data, Conn1, Stream1, Fin, Data}},
                                                {Actions, Batch, #state { response_status = Status,
                                                                          queued_sync_requests = Queue,
                                                                          response_body = Body } = AState})
                                                 when Conn1 == Conn andalso Stream1 == Stream ->
                                                   ResponseBody = [Data | Body],
                                                   case Fin of
                                                       fin ->
                                                           JSON = jsone:decode(iolist_to_binary(lists:reverse(ResponseBody))),
                                                           Response = case Status of
                                                                          200 ->
                                                                              {ok, JSON};
                                                                          _ ->
                                                                              {error, {Status, JSON}}
                                                                      end,
                                                           NewActions = lists:map(fun (From) ->
                                                                                          {reply, From, Response}
                                                                                  end, Queue),
                                                           {Actions ++ NewActions, Batch, AState#state {
                                                                                            post_in_flight = none,
                                                                                            queued_sync_requests = [],
                                                                                            response_status = undefined,
                                                                                            response_body = [] }};
                                                       nofin ->
                                                           {Actions, Batch, AState#state { response_body = ResponseBody}}
                                                   end;
                                               %% Empty response
                                               ({info, {gun_response, Conn1, Stream1, fin, Status, _Headers}}, 
                                                {Actions, Batch, #state { queued_sync_requests = Queue } = AState})
                                                 when Conn1 == Conn andalso Stream1 == Stream ->
                                                   Response = case Status of
                                                                  200 -> ok;
                                                                  _ -> {error, Status}
                                                              end,
                                                   NewActions = lists:map(fun (From) ->
                                                                                  {reply, From, Response}
                                                                          end, Queue),
                                                   {Actions ++ NewActions, Batch, AState#state {
                                                                                    post_in_flight = none,
                                                                                    queued_sync_requests = [],
                                                                                    response_status = undefined,
                                                                                    response_body = [] }};
                                               %% Response with body
                                               ({info, {gun_response, Conn1, Stream1, nofin, Status, _Headers}}, {Actions, Batch, AState})
                                                 when Conn1 == Conn andalso Stream1 == Stream ->
                                                   {Actions, Batch, AState#state { response_status = Status }};
                                               (_M, Acc) ->
                                                   Acc
                                  end, {[], [], State}, Ops),
    process_actions_and_batch(Actions, lists:reverse(Batch), State1,
                              timestamp_to_ms(apply_dependency(Clock, timestamp, []))).

-spec process_actions_and_batch([gen_batch_server:action()], [term()], #state{}, non_neg_integer()) -> 
          {ok, #state{}} |
          {ok, #state{}, {continue, term()}} |
          {ok, [gen_batch_server:action()], #state{}} |
          {ok, [gen_batch_server:action()], #state{}, {continue, term()}} |
          {stop, Reason :: term()}.

%% If there is nothing in the batch, don't do anything
process_actions_and_batch(Actions, [], #state { queue = [] } = State, _Time) ->
    {ok, Actions, State};
%% If queued batched and a new batch are still below the threshold for a minimum batch size
%% AND there's a timeout for low batch size greater than zero
%% AND that tiimeout hasn't expired
process_actions_and_batch(Actions, Batch, #state {
                                             queue = Queue,
                                             timeout_from = TimeoutFrom,
                                             config = #config { min_batch_size = MinBatchSize,
                                                                low_batch_size_timeout = Timeout }} = State, Time)
  when length(Batch) + length(Queue) < MinBatchSize andalso Timeout > 0
       andalso (TimeoutFrom == undefined orelse Time - TimeoutFrom < Timeout)
       ->
    erlang:send_after(Timeout - (Time - adjust_timeout_from(TimeoutFrom, Time)), self(), ping),
    {ok, Actions, State#state { queue = Queue ++ Batch, timeout_from = adjust_timeout_from(TimeoutFrom, Time) }};
%% Otherwise, we're ready to send the batch and actions
process_actions_and_batch(Actions, Batch, State, _Time) ->
    State1 = send_batch(Batch, State),
    {ok, Actions, State1}.

-spec adjust_timeout_from(undefined | non_neg_integer(), non_neg_integer()) -> non_neg_integer().

%% If it is a new timeout, it should be from now
adjust_timeout_from(undefined, Time) ->
    Time;
%% Otherwise, stick to the one previously set
adjust_timeout_from(Ts, _Time) -> Ts.


-spec send_batch([term()], #state{}) -> #state{}.

%% If there's nothing to send, do nothing
send_batch([], #state { queue = [] } = State) ->
    State;
%% If there's something to send, but requests must be ordered, and there's one in-flight
send_batch(Batch, #state { post_in_flight = Inflight, queue = Queue, config = #config { ordered = true } } = State) when Inflight =/= none ->
    %% then queue it (by adding two lists together to form a bigger batch)
    State#state { queue = Queue ++ Batch };
%% If we're good to send the batch now, send the queue and the batch
send_batch(Batch, #state { conn = Conn, queue = Queue, config = #config { gun = Gun, path = Path, api_key = ApiKey, source_id = SourceId } } = State) ->
    Batch1 = Queue ++ Batch,
    Stream = apply_dependency(Gun, post, 
                              [Conn, Path, [
                                            {<<"x-api-key">>, iolist_to_binary(ApiKey)},
                                            {<<"content-type">>, <<"application/bert">>}
                                           ],
                               bert:encode(#{ <<"source">> => iolist_to_binary(SourceId), <<"batch">> => Batch1 })]),
    State#state {
      queue = [],
      post_in_flight = Stream,
      timeout_from = undefined
     }.

-spec prepare_log(list() | map()) -> map().

%% Prepares a log record by ensuring it's a map.
prepare_log(Log) when is_list(Log) ->
    maps:from_list(Log);
prepare_log(Log) when is_map(Log) ->
    Log.

-spec timestamp_to_ms(erlang:timestamp()) -> non_neg_integer().

timestamp_to_ms({MegaSecs, Secs, MicroSecs}) ->
    MegaSecs * 1000000000 + 1000*Secs + (MicroSecs div 1000).
