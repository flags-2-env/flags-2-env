-module(flags2env_test).
-export([main/0]).

main() ->
  Config = filename:join([os:getenv("TMPDIR", "/tmp"), "flags2env-erlang-smoke.toml"]),
  ok = file:write_file(Config, iolist_to_binary([
    "[flags.port]\n",
    "env = \"PORT\"\n",
    "aliases = [\"port\"]\n",
    "type = \"integer\"\n\n",
    "[flags.debug]\n",
    "env = \"DEBUG\"\n",
    "aliases = [\"debug\"]\n",
    "type = \"bool\"\n",
    "true_aliases = [\"t\"]\n",
    "false_aliases = [\"f\"]\n"
  ])),
  Parsed = flags2env:parse(["app", "--debug=t", "--port", "8181"], Config),
  assert_map("parsed", Parsed, [{<<"DEBUG">>, <<"true">>}, {<<"PORT">>, <<"8181">>}]),

  Explicit = flags2env:parse(["app", "--debug=f"], Config),
  assert_map("explicit", Explicit, [{<<"DEBUG">>, <<"false">>}]),

  Combined = maps:merge(#{<<"PORT">> => <<"env">>, <<"KEEP">> => <<"1">>}, flags2env:parse(["app", "--port", "8181"], Config)),
  assert_map("combined", Combined, [{<<"PORT">>, <<"8181">>}, {<<"KEEP">>, <<"1">>}]),

  0 = flags2env:audit_config_status(Config),
  Structured = flags2env:parse_structured_json(["app", "--port", "8181"], Config),
  true = binary:match(Structured, <<"\"providedFlags\"">>) =/= nomatch,
  true = binary:match(Structured, <<"\"PORT\":\"8181\"">>) =/= nomatch,
  Rejected = flags2env:parse_structured_json(["app", "--definitely-unknown"], Config),
  true = binary:match(Rejected, <<"--definitely-unknown">>) =/= nomatch,

  ok = file:delete(Config),
  halt(0).

assert_map(Label, Map, Expected) ->
  case lists:all(fun({Key, Value}) -> maps:get(Key, Map, undefined) =:= Value end, Expected) of
    true -> ok;
    false -> io:format("unexpected ~s map: ~p~n", [Label, Map]), halt(1)
  end.
