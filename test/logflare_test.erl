-module(logflare_test).
-compile(nowarn_export_all).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

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

%% This one can never open a connection
-record(unreachable_gun, {dummy}).


open(#gun{} = G, _, _, _) ->
    {ok, G};

open(#unreachable_gun{} = G, _, _, _) ->
    {ok, G}.

await_up(#gun{} = G, _) ->
    {ok, G};

await_up(#unreachable_gun{}, _) ->
    {error, cant_reach}.

post(#gun{ rcvr = R}, _Conn, Path, Headers, Body) ->
    R ! {gun, post, Path, Headers, Body}.

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

post_request_test() ->
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

