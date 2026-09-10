//! Immutable environment snapshots for flags-2-env consumers.
//!
//! Process environment and argv are copied at the application boundary.
//! CLI overrides merge into an ordinary map. This module never writes
//! `std::env`.

use std::{collections::BTreeMap, fmt};

use crate::Flags2Env;

/// Deterministic environment snapshot. Prefer this over mutating process env.
pub type EnvMap = BTreeMap<String, String>;

/// Redacted error returned while binding admitted domain configuration to RuntimeConfig.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BindingError {
    /// A symbolic configuration field name is empty or unsafe for diagnostics.
    InvalidField,
    /// An admitted declaration references a malformed environment-key name.
    InvalidEnvKey { field: String },
    /// Two semantic fields reference the same environment key.
    DuplicateEnvKey { field: String },
    /// The final flags-2-env snapshot has no non-empty value for a declared field.
    MissingValue { field: String },
}

impl BindingError {
    /// Stable code suitable for startup diagnostics and fleet audit findings.
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::InvalidField => "invalid-field",
            Self::InvalidEnvKey { .. } => "invalid-env-key",
            Self::DuplicateEnvKey { .. } => "duplicate-env-key",
            Self::MissingValue { .. } => "missing-value",
        }
    }
}

impl fmt::Display for BindingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidField => formatter.write_str("domain config binding field is invalid"),
            Self::InvalidEnvKey { field } => write!(
                formatter,
                "domain config binding for {field} has an invalid environment key"
            ),
            Self::DuplicateEnvKey { field } => write!(
                formatter,
                "domain config binding for {field} reuses an environment key"
            ),
            Self::MissingValue { field } => write!(
                formatter,
                "domain config binding for {field} is missing from RuntimeConfig"
            ),
        }
    }
}

impl std::error::Error for BindingError {}

/// Pure merge: later override entries win over the initial map.
pub fn get_env_map(
    initial: EnvMap,
    overrides: impl IntoIterator<Item = (String, String)>,
) -> EnvMap {
    overrides
        .into_iter()
        .fold(initial, |mut env, (key, value)| {
            env.insert(key, value);
            env
        })
}

/// Return a trimmed non-empty value from an environment snapshot.
pub fn env_value<'a>(env: &'a EnvMap, key: &str) -> Option<&'a str> {
    env.get(key)
        .map(String::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

/// Resolve symbolic domain-config fields against an immutable flags-2-env environment snapshot.
///
/// `declarations` must come from a domain configuration document that has already passed that
/// domain's independent TypeSpec/JSON Schema admission. Environment-key names must use the
/// portable `^[A-Z_][A-Z0-9_]*$` grammar. A single environment key cannot silently control two
/// semantic fields, and empty/missing values fail closed.
///
/// Returned values are keyed by symbolic field name so downstream typed adapters never need to
/// re-read process environment or re-run argv parsing.
///
/// # Errors
/// Returns a redacted [`BindingError`]. Runtime values are never included in diagnostics.
pub fn resolve_bindings(
    env: &EnvMap,
    declarations: &BTreeMap<String, String>,
) -> Result<BTreeMap<String, String>, BindingError> {
    let mut resolved = BTreeMap::new();
    let mut owners = BTreeMap::<&str, &str>::new();

    for (field, env_key) in declarations {
        if !valid_field(field) {
            return Err(BindingError::InvalidField);
        }
        if !valid_env_key(env_key) {
            return Err(BindingError::InvalidEnvKey {
                field: field.clone(),
            });
        }
        if owners.insert(env_key.as_str(), field.as_str()).is_some() {
            return Err(BindingError::DuplicateEnvKey {
                field: field.clone(),
            });
        }
        let value = env_value(env, env_key)
            .ok_or_else(|| BindingError::MissingValue {
                field: field.clone(),
            })?
            .to_owned();
        resolved.insert(field.clone(), value);
    }

    Ok(resolved)
}

fn valid_field(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn valid_env_key(value: &str) -> bool {
    let Some(first) = value.bytes().next() else {
        return false;
    };
    (first.is_ascii_uppercase() || first == b'_')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
}

/// Copy the process environment. Impure boundary helper.
pub fn process_env_map() -> EnvMap {
    std::env::vars().collect()
}

/// Copy process arguments. Impure boundary helper.
pub fn process_argv() -> Vec<String> {
    std::env::args().collect()
}

/// Parse argv through the dynamically loaded flags2env library.
///
/// Does not write the process environment. Prefer [`BundledFlags2Env`] in
/// binaries that statically link the parser, then pass the resulting flags
/// into [`get_env_map`].
pub fn cli_overrides(argv: &[String]) -> Result<EnvMap, String> {
    let parser = unsafe { Flags2Env::load(None) }
        .map_err(|error| format!("flags-2-env unavailable: {error}"))?;
    parser
        .parse(argv, None)
        .map(|overrides| overrides.into_iter().collect())
        .map_err(|error| format!("invalid CLI flags: {error}"))
}

/// Merge argv overrides into a copied environment without process mutation.
///
/// Load or parse failures keep `initial`, matching the historical fallback
/// that left process env unchanged on error.
pub fn env_map_from_argv(initial: EnvMap, argv: &[String]) -> EnvMap {
    match cli_overrides(argv) {
        Ok(overrides) => get_env_map(initial, overrides),
        Err(_) => initial,
    }
}

/// Build the application environment: process env + CLI overrides.
pub fn current_env_map() -> EnvMap {
    env_map_from_argv(process_env_map(), &process_argv())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_values_override_environment_values() {
        let initial = EnvMap::from([
            ("PORT".into(), "3000".into()),
            ("HOST".into(), "localhost".into()),
        ]);
        let overrides = EnvMap::from([("PORT".into(), "8080".into())]);
        let env = get_env_map(initial, overrides);

        assert_eq!(env.get("PORT").map(String::as_str), Some("8080"));
        assert_eq!(env.get("HOST").map(String::as_str), Some("localhost"));
    }

    #[test]
    fn empty_override_still_wins() {
        let initial = EnvMap::from([("RUST_LOG".into(), "info".into())]);
        let env = get_env_map(initial, [("RUST_LOG".into(), String::new())]);
        assert_eq!(env.get("RUST_LOG").map(String::as_str), Some(""));
        assert_eq!(env_value(&env, "RUST_LOG"), None);
    }

    #[test]
    fn merge_does_not_mutate_process_environment() {
        let before = std::env::var_os("FLAGS2ENV_ENV_MAP_PROBE");
        let env = get_env_map(
            EnvMap::from([("FLAGS2ENV_ENV_MAP_PROBE".into(), "base".into())]),
            [("FLAGS2ENV_ENV_MAP_PROBE".into(), "override".into())],
        );
        assert_eq!(env.get("PORT").map(String::as_str), None);
        assert_eq!(
            env.get("FLAGS2ENV_ENV_MAP_PROBE").map(String::as_str),
            Some("override")
        );
        assert_eq!(std::env::var_os("FLAGS2ENV_ENV_MAP_PROBE"), before);
    }

    #[test]
    fn domain_bindings_resolve_only_declared_final_values() {
        let env = EnvMap::from([
            (
                "SHARED_AUTH_URL".to_string(),
                "https://auth.example.test".to_string(),
            ),
            (
                "AUTH_CALLBACK_URL".to_string(),
                "https://app.example.test/callback".to_string(),
            ),
            ("UNRELATED_SECRET".to_string(), "must-not-leak".to_string()),
        ]);
        let declarations = BTreeMap::from([
            ("auth.authority".to_string(), "SHARED_AUTH_URL".to_string()),
            ("auth.callback".to_string(), "AUTH_CALLBACK_URL".to_string()),
        ]);
        let resolved = resolve_bindings(&env, &declarations).unwrap();
        assert_eq!(resolved.len(), 2);
        assert_eq!(resolved["auth.authority"], "https://auth.example.test");
        assert!(!resolved.values().any(|value| value == "must-not-leak"));
    }

    #[test]
    fn domain_bindings_fail_closed_on_missing_empty_or_invalid_keys() {
        let mut env = EnvMap::from([("GOOD_KEY".to_string(), "value".to_string())]);
        let declarations = BTreeMap::from([
            ("feature.one".to_string(), "GOOD_KEY".to_string()),
            ("feature.two".to_string(), "MISSING_KEY".to_string()),
        ]);
        assert!(matches!(
            resolve_bindings(&env, &declarations),
            Err(BindingError::MissingValue { .. })
        ));
        env.insert("MISSING_KEY".to_string(), "  ".to_string());
        assert!(matches!(
            resolve_bindings(&env, &declarations),
            Err(BindingError::MissingValue { .. })
        ));

        let malformed = BTreeMap::from([("feature.url".to_string(), "bad-key".to_string())]);
        assert!(matches!(
            resolve_bindings(&env, &malformed),
            Err(BindingError::InvalidEnvKey { .. })
        ));
    }

    #[test]
    fn domain_bindings_reject_aliasing_and_redact_runtime_values() {
        let marker = "synthetic-secret-never-reflect";
        let env = EnvMap::from([("GOOD_KEY".to_string(), marker.to_string())]);
        let duplicate = BTreeMap::from([
            ("feature.one".to_string(), "GOOD_KEY".to_string()),
            ("feature.two".to_string(), "GOOD_KEY".to_string()),
        ]);
        let error = resolve_bindings(&env, &duplicate).unwrap_err();
        assert!(matches!(error, BindingError::DuplicateEnvKey { .. }));
        let rendered = format!("{error:?} {error}");
        assert!(!rendered.contains(marker));
    }

    #[test]
    fn source_does_not_write_process_environment() {
        const SRC: &str = include_str!("env_map.rs");
        let production = SRC.split("#[cfg(test)]").next().unwrap_or(SRC);
        assert!(!production.contains("set_var"));
    }
}
