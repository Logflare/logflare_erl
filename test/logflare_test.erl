-module(logflare_test).
-compile(nowarn_export_all).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

%% Logger support

log(Msg, #{report_to := ReportTo} = Meta) ->
    ReportTo ! {log, Msg, Meta}.

-record(clock, {
                ts :: atomics:atomics_ref()
               }).

%%% Mock Clock

new_clock() ->
    #clock {
       ts = atomics:new(3, [{signed, false}])
      }.

new_clock(Ts) ->
    T = atomics:new(3, [{signed, false}]),
    clock_set(#clock {ts = T}, Ts).

clock_set(#clock { ts = T} = Clock, {MegaSecs, Secs, MicroSecs}) ->
    atomics:put(T, 1, MegaSecs),
    atomics:put(T, 2, Secs),
    atomics:put(T, 3, MicroSecs),
    Clock.

timestamp(#clock { ts = Ts }) ->
    Mega = atomics:get(Ts, 1),
    Secs = atomics:get(Ts, 2),
    Micros = atomics:get(Ts, 3),
    {Mega, Secs, Micros}.

timestamp_to_ms({MegaSecs, Secs, MicroSecs}) ->
    MegaSecs * 1000000000 + 1000*Secs + (MicroSecs div 1000).

%% * internal test for test's mock clock
%%
%% Ensures that timestamp returned for the clock matches
%% what's inside
internal_clock_timestamp_test() ->
    Ts = erlang:timestamp(),
    ?assertEqual(Ts, timestamp(new_clock(Ts))).

%% * internal test for test's mock clock
%%
%% Ensures that timestamp can be updated
internal_clock_timestamp_set_test() ->
    Ts = erlang:timestamp(),
    {Mega, Secs, Micro} = Ts,
    C = new_clock(Ts),
    NewTs = {Mega, Secs + 1, Micro},
    clock_set(C, NewTs),
    ?assertEqual(NewTs, timestamp(C)).

%%% Mock Gun (HTTP client)

%% Regular mock client
-record(gun, {rcvr}).

new_gun() ->
    #gun{ rcvr = self() }.

%% Error mock client
-record(error_gun, {rcvr}).
new_error_gun() ->
    #error_gun{ rcvr = self() }.


%% This one can never open a connection
-record(unreachable_gun, {dummy}).


open(#unreachable_gun{} = G, _, _, _) ->
    {ok, G};
open(G, _, _, _) ->
    {ok, G}.

await_up(#unreachable_gun{}, _) ->
    {error, cant_reach};
await_up(G, _) ->
    {ok, G}.


post(#gun{ rcvr = R}, Conn, Path, Headers, Body) ->
    Self = self(),
    Stream = make_ref(),
    R ! {gun, post, Path, Headers, Body},
    Self ! {gun_response, Conn, Stream, nofin, 200, []},
    Self ! {gun_data, Conn, Stream, nofin, <<"\"succ">>},
    Self ! {gun_data, Conn, Stream, fin, <<"ess\"">>},
    Stream;

post(#error_gun{ rcvr = R}, Conn, Path, Headers, Body) ->
    Self = self(),
    Stream = make_ref(),
    R ! {gun, post, Path, Headers, Body},
    Self ! {gun_response, Conn, Stream, nofin, 404, []},
    Self ! {gun_data, Conn, Stream, nofin, <<"\"not_">>},
    Self ! {gun_data, Conn, Stream, fin, <<"found\"">>},
    Stream.


%%% Actual tests

%% Should not start if can't open the HTTP host
crash_if_cant_open_test() ->
    Self = self(),
    %% Isolated execution to avoid bringing down
    %% EUnit's processes upon death of a linked process
    spawn(fun () ->
                  Gun = {?MODULE, #unreachable_gun{}},
                  Self ! logflare:start_link([{gun, Gun}])
          end),
    receive M ->
            ?assertEqual({error, cant_reach}, M)
    end.

async_test() ->
    Gun = new_gun(),
    {ok, L} = logflare:start_link([
                                   {source_id, "123"},
                                   {api_key, "000"},
                                   {gun, {?MODULE, Gun}}
                                  ]),
    Log = #{test => passed},
    logflare:async(L, Log),
    receive
        {gun, post, <<"/logs/erlang/logger">>, Headers, Body} ->
            ?assertEqual(<<"000">>,
                         maps:get(<<"x-api-key">>, maps:from_list(Headers))),
            Decoded = bert:decode(Body),
            ?assertEqual(#{<<"batch">> => [Log],
                           <<"source">> => <<"123">>
                          }, Decoded)
    end.

async_order_test() ->
    Gun = new_gun(),
    {ok, L} = logflare:start_link([
                                   {source_id, "123"},
                                   {api_key, "000"},
                                   {gun, {?MODULE, Gun}},
                                   {min_batch_size, 2},
                                   {low_batch_size_timeout, 10000}
                                  ]),
    Log1 = #{test => 1},
    Log2 = #{test => 2},
    logflare:async(L, Log1),
    logflare:async(L, Log2),
    receive
        {gun, post, <<"/logs/erlang/logger">>, Headers, Body} ->
            ?assertEqual(<<"000">>,
                         maps:get(<<"x-api-key">>, maps:from_list(Headers))),
            Decoded = bert:decode(Body),
            ?assertEqual(#{<<"batch">> => [Log1, Log2],
                           <<"source">> => <<"123">>
                          }, Decoded)
    end.

async_batch_order_test() ->
    Gun = new_gun(),
    {ok, L} = logflare:start_link([
                                   {source_id, "123"},
                                   {api_key, "000"},
                                   {gun, {?MODULE, Gun}},
                                   {min_batch_size, 2},
                                   {low_batch_size_timeout, 10000}
                                  ]),
    Log1 = #{test => 1},
    Log2 = #{test => 2},
    logflare:async_batch(L, [Log1, Log2]),
    receive
        {gun, post, <<"/logs/erlang/logger">>, Headers, Body} ->
            ?assertEqual(<<"000">>,
                         maps:get(<<"x-api-key">>, maps:from_list(Headers))),
            Decoded = bert:decode(Body),
            ?assertEqual(#{<<"batch">> => [Log1, Log2],
                           <<"source">> => <<"123">>
                          }, Decoded)
    end.

sync_test() ->
    Gun = new_gun(),
    {ok, L} = logflare:start_link([
                                   {source_id, "123"},
                                   {api_key, "000"},
                                   {gun, {?MODULE, Gun}}
                                  ]),
    Log = #{test => passed},
    ?assertEqual({ok, <<"success">>}, logflare:sync(L, Log)).

sync_error_test() ->
    Gun = new_error_gun(),
    {ok, L} = logflare:start_link([
                                   {source_id, "123"},
                                   {api_key, "000"},
                                   {gun, {?MODULE, Gun}}
                                  ]),
    Log = #{test => passed},
    ?assertEqual({error, {404, <<"not_found">>}}, logflare:sync(L, Log)).

async_error_logging_test() ->
    Gun = new_error_gun(),
    {ok, L} = logflare:start_link([
                                   {source_id, "123"},
                                   {api_key, "000"},
                                   {gun, {?MODULE, Gun}}
                                  ]),
    Log = #{test => passed},
    logger:add_handler(?MODULE, ?MODULE, #{report_to => self()}),
    logflare:async(L, Log),
    receive
        {log, #{msg := {"POST request to Logflare failed (~d) ~p", [404, <<"not_found">>]}},_} ->
            ok
    end,
    logger:remove_handler(?MODULE).
