use std::collections::HashMap;

use flags2env::StructuredParse;

fn parse_with(unknown_options: &[&str], extras: &[&str], errors: &[&str]) -> StructuredParse {
    StructuredParse {
        flags: HashMap::new(),
        provided_flags: HashMap::new(),
        dotenv: HashMap::new(),
        dotenv_overrides: HashMap::new(),
        source_order: HashMap::new(),
        command: String::new(),
        subcommands: Vec::new(),
        extras: extras.iter().map(|value| (*value).to_owned()).collect(),
        unknown_options: unknown_options
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
        errors: errors.iter().map(|value| (*value).to_owned()).collect(),
    }
}

#[test]
fn unknown_option_names_strip_inline_values() {
    let parsed = parse_with(&["--token=do-not-print", "--all"], &[], &[]);
    assert_eq!(
        parsed.sanitized_unknown_option_names(),
        vec!["--token".to_owned(), "--all".to_owned()]
    );
}

#[test]
fn unsafe_unknown_option_text_is_not_returned() {
    let parsed = parse_with(
        &["--token=secret", "not an option", "--bad/value"],
        &[],
        &[],
    );
    assert_eq!(
        parsed.sanitized_unknown_option_names(),
        vec!["--token".to_owned()]
    );
}

#[test]
fn command_candidate_requires_portable_shell_word() {
    assert_eq!(
        parse_with(&[], &["create-repo"], &[]).sanitized_command_candidate(),
        Some("create-repo".to_owned())
    );
    assert_eq!(
        parse_with(&[], &["secret positional value"], &[]).sanitized_command_candidate(),
        None
    );
    assert_eq!(
        parse_with(&[], &["--token=secret"], &[]).sanitized_command_candidate(),
        None
    );
}

#[test]
fn summary_names_safe_options_but_counts_value_bearing_channels() {
    let parsed = parse_with(
        &["--all", "--token=do-not-print"],
        &["private positional"],
        &["invalid value: do-not-print"],
    );
    let summary = parsed.redacted_diagnostic_summary();
    assert!(summary.contains("unknown options: --all, --token"));
    assert!(summary.contains("1 parse error"));
    assert!(summary.contains("1 positional extra"));
    assert!(!summary.contains("do-not-print"));
    assert!(!summary.contains("private positional"));
}

#[test]
fn clean_parse_has_explicit_clean_summary() {
    assert_eq!(
        parse_with(&[], &[], &[]).redacted_diagnostic_summary(),
        "no invocation errors"
    );
}
