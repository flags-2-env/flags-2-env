-module(flags2env).
-on_load(init/0).
-compile({no_auto_import, [apply/2]}).

-export([
  parse_process/0,
  parse_process/1,
  parse/1,
  parse/2,
  parse_structured_json/1,
  parse_structured_json/2,
  help_requested/1,
  help_table_for_argv/4,
  audit_config_json/0,
  audit_config_json/1,
  audit_config_status/0,
  audit_config_status/1,
  apply_process/0,
  apply_process/1,
  apply/1,
  apply/2,
  env_map/0
]).

init() ->
  PrivDir =
    case code:priv_dir(?MODULE) of
      {error, _} -> filename:join(filename:dirname(code:which(?MODULE)), "../priv");
      Dir -> Dir
    end,
  erlang:load_nif(filename:join(PrivDir, "flags2env_nif"), 0).

parse_process() ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

parse_process(_ConfigPath) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

parse(_Argv) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

parse(_Argv, _ConfigPath) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

parse_structured_json(_Argv) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

parse_structured_json(_Argv, _ConfigPath) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

help_requested(_Argv) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

help_table_for_argv(_Argv, _CommandName, _TerminalColumns, _ConfigPath) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

audit_config_json() ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

audit_config_json(_ConfigPath) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

audit_config_status() ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

audit_config_status(_ConfigPath) ->
  erlang:nif_error({nif_not_loaded, ?MODULE}).

apply_process() ->
  apply_process(env_map()).

apply_process(Env) ->
  maps:merge(Env, parse_process()).

apply(Argv) ->
  apply(Argv, env_map()).

apply(Argv, Env) ->
  maps:merge(Env, parse(Argv)).

env_map() ->
  lists:foldl(fun env_entry_to_map/2, #{}, os:getenv()).

env_entry_to_map(Entry, Acc) ->
  case string:split(Entry, "=", leading) of
    [Key, Value] ->
      maps:put(unicode:characters_to_binary(Key), unicode:characters_to_binary(Value), Acc);
    _ ->
      Acc
  end.
