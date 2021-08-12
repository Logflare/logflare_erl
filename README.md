# Logflare API Client for Erlang

Send any kind of timestamped event data to Logflare for ingest. This library is separated from the `logflare_lager_backend` and the `logfalre_logger_handler` so you can easily send Logfalre data without pushing it through a logging framework if you don't need the context those frameworks offer and don't want the added overhead. All Logflare Erlang clients depend on this client to shuffle data to Logflare.

## Quick Start

Add `logflare_erl` to your Rebar3 dependancies.

```erlang
{deps,[
  {logflare_erl, "0.2.0"}}
]}.
```

Setup your client.

```erlang
-module(client).

-export([config/0, conn/1, post/2, post_async/2, timestamp_to_ms/1]).

config() ->
    [{api_key, "YOUR_LOGFLARE_API_KEY"},
     {source_id, "YOUR_SOURCE_UUID"},
     {base_url, <<"https://api.logflare.app">>},
     {path, <<"/logs/erlang/logger">>}].

conn(Config) ->
    {ok, Pid} = logflare:start_link(Config),
    Pid.

post(Conn, Log) ->
    logflare:sync(Conn, Log).

post_async(Conn, Log) ->
    logflare:async(Conn, Log).

timestamp_to_ms({MegaSecs, Secs, MicroSecs}) ->
    MegaSecs * 1000000000 + 1000 * Secs + MicroSecs div 1000.

```

Send Logflare some data.

```
Erlang/OTP 24 [erts-12.0.3] [source] [64-bit] [smp:16:16] [ds:16:16:10] [async-threads:1] [jit] [dtrace]

Eshell V12.0.3  (abort with ^G)
1> Config = client:config().
[{api_key,"ecKGEvgLuTVB"},
 {source_id,"53e8a0ab-3d78-4446-a3f8-eb8fbe3bbff2"},
 {base_url,<<"https://api.logflare.app">>},
 {path,<<"/logs/erlang/logger">>}]
2> Conn = client:conn(Config).
<0.330.0>
3> Timestamp = client:timestamp_to_ms(erlang:timestamp()).
1628699850325
4> Log = #{<<"timestamp">> => Timestamp, <<"message">> => <<"New log message!">>, <<"metadata">> => #{<<"product">> => <<"tshirt">>, <<"color">> => <<"blue">>}}.
#{<<"message">> => <<"New log message!">>,
  <<"metadata">> =>
      #{<<"color">> => <<"blue">>,<<"product">> => <<"tshirt">>},
  <<"timestamp">> => 1628699850325}
5> client:post(Conn, Log).
{ok,#{<<"message">> => <<"Logged!">>}}
6> 
```

Query Logflare! 

You can now use the Logflare Query Language to easily query your `message` or `metadata`. To find all blue shirts simply search for `m.color:blue m.product:tshirt`. The `message` field is implied so you can search with any string and it'll query the `message` field. To match all messages like the one above just search `log message`.

## Supervision

You'll want to add this to your supervision tree when your app boots so you always have it ready to send data to Logflare.

## Batching

This client handles batching transparently. Simply `logflare:async(Pid, Log).` and it'll batch log events over to Logflare when batching is needed. Batching is handled by the `gen_batch_server` library.

## Encoding

We encode the data in the Binary Erlang Term Format and Logflare is written in Elixir, so all native Erlang types are supported. Logflare will handle transoforming those types into something the storage backend can handle.

## Event Structure

By default the `/logs/erlang/logger` endpoint requires two top level keys: `message` and `metadata`. The `message` is what you'll see in your log stream. The `metadata` is attached to each log message and can be any object, nested with any keys however deep. Logflare typechecks the metadata and migrates the backend based on any new fields found. 

Optionally you can include the `timestamp` field and Logflare will use your `timestamp` as the official timestamp of the log event. Otherwise events will be timestamped as Logflare ingests them. The timestamp can be an `ISO8601` formatted string or a Unix Epoch integer. 

## Gotchas

The default backend of Logflare is BigQuery. BigQuery is typed. The data type of a field is defined by the first log event Logflare sees. Sometimes people will send over an integer first, and then it turns into a float. In this case the field would be defined as an integer and subsequent events will be rejected, appearing the `rejected` queue in your Logflare dashboard. You should also see a message in stdout if an event is rejected for any reason.

Logflare supports and encourages wide events, but you should be concious of what your logging. Depending on the backend, we may not be able to easily delete columns. If you blindly send a map, fields in that map will be added which you may not need and spam your schema. If you need to log an unknown structure, first stringify it and include it in the metadata as a string, then if there is data in there you'd like on an ongoing basis, pull that out into it's own field. 

## Build

```
rebar3 compile
```

## Test

```
rebar3 eunit
```
