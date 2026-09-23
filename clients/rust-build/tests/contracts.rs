use flags2env::BundledFlags2Env;
use flags2env_build::{generate_into, generate_types, Language};
use std::fs;

const CONTRACT: &str = r#"
[env]
files = []
[parse]
allow_unknown = false
[flags.json]
env = "JSON_ENABLED"
aliases = ["json"]
type = "bool"
default = true
[flags.limit]
env = "LIMIT"
aliases = ["limit"]
type = "integer"
default = 10
"#;

const SHARED_ENV_COMMAND_CONTRACT: &str = r#"
[env]
files = []
[parse]
allow_unknown = false

[commands.sync]
env = "COMMAND_SYNC"
[commands.sync.flags.given]
env = "RPC_GIVEN"
aliases = ["given"]
type = "string"

[commands.rpc]
env = "COMMAND_RPC"
[commands.rpc.commands.sync]
env = "COMMAND_RPC_SYNC"
[commands.rpc.commands.sync.flags.given]
env = "RPC_GIVEN"
aliases = ["given"]
type = "string"
"#;

#[test]
fn generates_rust_schema_and_exact_embeddable_contract() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join(".cli-flags.toml");
    fs::write(&config, CONTRACT).unwrap();
    let files = generate_into(&config, &dir.path().join("out"), "CliConfig").unwrap();
    let rust = fs::read_to_string(files.rust).unwrap();
    assert!(rust.contains("CliConfig"));
    assert!(rust.contains("JSON_ENABLED"));
    assert!(rust.contains("bool"));
    let schema: serde_json::Value =
        serde_json::from_slice(&fs::read(files.schema).unwrap()).unwrap();
    assert!(schema.is_object());
    assert_eq!(fs::read_to_string(files.contract).unwrap(), CONTRACT);
}

#[test]
fn renaming_a_contract_key_changes_the_generated_field() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join(".cli-flags.toml");
    fs::write(&config, CONTRACT.replace("JSON_ENABLED", "RENAMED_JSON")).unwrap();
    let rust = generate_types(&config, Language::Rust, "CliConfig").unwrap();
    assert!(!rust.contains("JSON_ENABLED"));
    assert!(rust.contains("RENAMED_JSON"));
}

#[test]
fn canonical_negation_and_last_occurrence_use_the_native_parser() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join(".cli-flags.toml");
    fs::write(&config, CONTRACT).unwrap();
    for (args, expected) in [
        (vec!["app"], "true"),
        (vec!["app", "--no-json"], "false"),
        (vec!["app", "--json=false"], "false"),
        (vec!["app", "--json", "--no-json"], "false"),
        (vec!["app", "--no-json", "--json"], "true"),
    ] {
        let args = args.into_iter().map(str::to_owned).collect::<Vec<_>>();
        let parsed = BundledFlags2Env::new()
            .parse_structured(&args, config.to_str())
            .unwrap();
        assert!(parsed.errors.is_empty(), "{:?}", parsed.errors);
        assert!(parsed.unknown_options.is_empty());
        assert_eq!(parsed.flags.get("JSON_ENABLED").unwrap(), expected);
    }
}

#[test]
fn shared_env_across_compatibility_command_scopes_generates_one_rust_field() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join(".cli-flags.toml");
    fs::write(&config, SHARED_ENV_COMMAND_CONTRACT).unwrap();
    let rust = generate_types(&config, Language::Rust, "CliConfig").unwrap();
    assert_eq!(rust.matches("pub RPC_GIVEN:").count(), 1, "{rust}");
    assert!(rust.contains("pub RPC_GIVEN: Option<String>"), "{rust}");

    for argv in [
        vec!["app", "sync", "--given", "api"],
        vec!["app", "rpc", "sync", "--given", "api"],
    ] {
        let args = argv.into_iter().map(str::to_owned).collect::<Vec<_>>();
        let parsed = BundledFlags2Env::new()
            .parse_structured(&args, config.to_str())
            .unwrap();
        assert!(parsed.errors.is_empty(), "{:?}", parsed.errors);
        assert_eq!(parsed.flags.get("RPC_GIVEN").map(String::as_str), Some("api"));
    }
}

#[test]
fn unknown_options_and_invalid_types_remain_errors() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join(".cli-flags.toml");
    fs::write(&config, CONTRACT).unwrap();
    for arg in ["--misspelled", "--limit=not-an-integer", "--json=perhaps"] {
        let parsed = BundledFlags2Env::new()
            .parse_structured(&["app".into(), arg.into()], config.to_str())
            .unwrap();
        assert!(!parsed.errors.is_empty() || !parsed.unknown_options.is_empty());
    }
}

#[test]
fn invalid_type_names_and_missing_contracts_fail_closed() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missing.toml");
    assert!(generate_types(&path, Language::Rust, "CliConfig").is_err());
    assert!(generate_types(&path, Language::Rust, "Config; injected()").is_err());
}
