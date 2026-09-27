defmodule Flags2Env do
  @moduledoc false

  def parse_process do
    :flags2env.parse_process()
  end

  def parse_process(config_path) do
    :flags2env.parse_process(config_path)
  end

  def parse(argv) do
    :flags2env.parse(argv)
  end

  def parse(argv, config_path) do
    :flags2env.parse(argv, config_path)
  end

  def parse_structured_json(argv) do
    :flags2env.parse_structured_json(argv)
  end

  def parse_structured_json(argv, config_path) do
    :flags2env.parse_structured_json(argv, config_path)
  end

  def audit_config_json do
    :flags2env.audit_config_json()
  end

  def audit_config_json(config_path) do
    :flags2env.audit_config_json(config_path)
  end

  def audit_config_status do
    :flags2env.audit_config_status()
  end

  def audit_config_status(config_path) do
    :flags2env.audit_config_status(config_path)
  end

  def apply_process(env \\ System.get_env()) do
    Map.merge(env, parse_process())
  end

  def apply(argv, env \\ System.get_env()) do
    Map.merge(env, parse(argv))
  end

  def apply(argv, env, config_path) do
    Map.merge(env, parse(argv, config_path))
  end

  def env_map do
    System.get_env()
  end
end
