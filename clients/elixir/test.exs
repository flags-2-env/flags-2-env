config = Path.join(System.tmp_dir!(), "flags2env-elixir-smoke.toml")
System.at_exit(fn _ -> File.rm(config) end)

File.write!(config, """
[flags.port]
env = "PORT"
aliases = ["port"]
type = "integer"

[flags.debug]
env = "DEBUG"
aliases = ["debug"]
type = "bool"
true_aliases = ["t"]
false_aliases = ["f"]
""")

parsed = Flags2Env.parse(["app", "--debug=t", "--port", "8181"], config)

unless parsed["DEBUG"] == "true" and parsed["PORT"] == "8181" do
  IO.inspect(parsed, label: "unexpected parsed map")
  System.halt(1)
end

explicit = Flags2Env.parse(["app", "--debug=f"], config)

unless explicit["DEBUG"] == "false" do
  IO.inspect(explicit, label: "unexpected explicit config map")
  System.halt(1)
end

combined = Map.merge(%{"PORT" => "env", "KEEP" => "1"}, Flags2Env.parse(["app", "--port", "8181"], config))

unless combined["PORT"] == "8181" and combined["KEEP"] == "1" do
  IO.inspect(combined, label: "unexpected combined map")
  System.halt(1)
end


unless Flags2Env.audit_config_status(config) == 0 do
  IO.puts(:stderr, "flags contract audit should pass")
  System.halt(1)
end

structured = Flags2Env.parse_structured_json(["app", "--port", "8181"], config)

unless String.contains?(structured, "\"providedFlags\"") and
         String.contains?(structured, "\"PORT\":\"8181\"") do
  IO.inspect(structured, label: "unexpected structured report")
  System.halt(1)
end

rejected = Flags2Env.parse_structured_json(["app", "--definitely-unknown"], config)

unless String.contains?(rejected, "--definitely-unknown") do
  IO.inspect(rejected, label: "unknown option missing from structured report")
  System.halt(1)
end


unless Flags2Env.help_requested(["app", "--help"]) do
  IO.puts(:stderr, "exact --help token should be detected")
  System.halt(1)
end

help = Flags2Env.help_table_for_argv(["app", "--help"], "app", 100, config)

unless String.contains?(help, "--port") do
  IO.inspect(help, label: "contract-generated help missing declared port flag")
  System.halt(1)
end
