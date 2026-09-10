//! Immutable environment snapshots for flags-2-env consumers.
//!
//! Process environment and argv are copied at the application boundary.
//! CLI overrides merge into an ordinary map. This module never writes
//! `std::env`.

use std::{collections::BTreeMap, fmt};

use serde_json::Value;

use crate::Flags2Env;

/// Deterministic environment snapshot. Prefer this over mutating process env.
pub type EnvMap = BTreeMap<String, String>;

/// Stable machine code for a required environment value that is absent.
pub const ENV_MISSING: &str = "ENV_MISSING";
/// Stable machine code for an environment value that is present but not canonical/parseable.
pub const ENV_PARSE: &str = "ENV_PARSE";
/// Stable machine code for an invalid environment declaration.
pub const ENV_CONTRACT: &str = "ENV_CONTRACT";

/// Portable scalar/container kinds used by ORES runtime environment contracts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvValueKind {
    String,
    Bool,
    Integer,
    Double,
    Json,
    Array,
    Map,
}

impl EnvValueKind {
    /// Parse the canonical cross-runtime name used by runtime TOML contracts.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "string" => Some(Self::String),
            "bool" => Some(Self::Bool),
            "integer" => Some(Self::Integer),
            "double" | "float" => Some(Self::Double),
            "json" => Some(Self::Json),
            "array" => Some(Self::Array),
            "map" => Some(Self::Map),
            _ => None,
        }
    }

    /// Canonical name used in diagnostics and conformance fixtures.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::String => "string",
            Self::Bool => "bool",
            Self::Integer => "integer",
            Self::Double => "double",
            Self::Json => "json",
            Self::Array => "array",
            Self::Map => "map",
        }
    }
}

/// One admitted runtime-config binding to the immutable environment snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvBindingSpec {
    pub field: String,
    pub env_key: String,
    pub kind: EnvValueKind,
    pub required: bool,
    pub secret: bool,
    pub allow_empty: bool,
}

impl EnvBindingSpec {
    /// Construct a required, non-empty binding.
    #[must_use]
    pub fn required(
        field: impl Into<String>,
        env_key: impl Into<String>,
        kind: EnvValueKind,
    ) -> Self {
        Self {
            field: field.into(),
            env_key: env_key.into(),
            kind,
            required: true,
            secret: false,
            allow_empty: false,
        }
    }

    /// Construct an optional binding that is validated whenever it is present.
    #[must_use]
    pub fn optional(
        field: impl Into<String>,
        env_key: impl Into<String>,
        kind: EnvValueKind,
    ) -> Self {
        Self {
            field: field.into(),
            env_key: env_key.into(),
            kind,
            required: false,
            secret: false,
            allow_empty: false,
        }
    }

    /// Mark the binding secret so callers can preserve that fact in diagnostics.
    #[must_use]
    pub const fn secret(mut self, secret: bool) -> Self {
        self.secret = secret;
        self
    }

    /// Explicitly permit an empty string for string bindings.
    #[must_use]
    pub const fn allow_empty(mut self, allow_empty: bool) -> Self {
        self.allow_empty = allow_empty;
        self
    }
}

/// Redacted deterministic preflight diagnostic. Runtime values are never stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvDiagnostic {
    pub code: &'static str,
    pub name: String,
    pub expected: String,
    pub secret: bool,
}

impl fmt::Display for EnvDiagnostic {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "{}: {} must be {}",
            self.code, self.name, self.expected
        )
    }
}

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

/// Validate and type all admitted environment declarations in one deterministic pass.
///
/// Every present value is checked, including optional values. Missing required values,
/// malformed declarations, duplicate keys, and values that are not canonical for the declared
/// kind are collected and returned together. The function is pure and never reads or mutates the
/// process environment.
///
/// CLI aliases are expected to be normalized by flags-2-env before this function is called. This
/// means `--feature=yes` may become the canonical string `true`, while a raw environment value of
/// `FEATURE=yes` is rejected instead of being interpreted differently by each language runtime.
///
/// Returned values are typed JSON values keyed by symbolic field name. This gives callers an
/// immutable, language-neutral `RuntimeConfig` representation without a second ad-hoc parser.
///
/// # Errors
/// Returns a stable, redacted diagnostic list sorted by environment key and symbolic field name.
pub fn resolve_typed_bindings(
    env: &EnvMap,
    specs: &[EnvBindingSpec],
) -> Result<BTreeMap<String, Value>, Vec<EnvDiagnostic>> {
    let mut ordered = specs.to_vec();
    ordered.sort_by(|left, right| {
        left.env_key
            .cmp(&right.env_key)
            .then_with(|| left.field.cmp(&right.field))
    });

    let mut resolved = BTreeMap::new();
    let mut owners = BTreeMap::<String, String>::new();
    let mut diagnostics = Vec::new();

    for spec in ordered {
        if !valid_field(&spec.field) {
            diagnostics.push(EnvDiagnostic {
                code: ENV_CONTRACT,
                name: spec.field,
                expected: "portable symbolic field name".to_string(),
                secret: spec.secret,
            });
            continue;
        }
        if !valid_env_key(&spec.env_key) {
            diagnostics.push(EnvDiagnostic {
                code: ENV_CONTRACT,
                name: spec.env_key,
                expected: "environment key matching ^[A-Z_][A-Z0-9_]*$".to_string(),
                secret: spec.secret,
            });
            continue;
        }
        if owners
            .insert(spec.env_key.clone(), spec.field.clone())
            .is_some()
        {
            diagnostics.push(EnvDiagnostic {
                code: ENV_CONTRACT,
                name: spec.env_key,
                expected: "unique environment key".to_string(),
                secret: spec.secret,
            });
            continue;
        }

        let Some(raw) = env.get(&spec.env_key) else {
            if spec.required {
                diagnostics.push(EnvDiagnostic {
                    code: ENV_MISSING,
                    name: spec.env_key,
                    expected: spec.kind.as_str().to_string(),
                    secret: spec.secret,
                });
            }
            continue;
        };

        match parse_canonical_env_value(spec.kind, raw, spec.allow_empty) {
            Some(value) => {
                resolved.insert(spec.field, value);
            }
            None => diagnostics.push(EnvDiagnostic {
                code: ENV_PARSE,
                name: spec.env_key,
                expected: if spec.kind == EnvValueKind::String && !spec.allow_empty {
                    "non-empty string".to_string()
                } else {
                    spec.kind.as_str().to_string()
                },
                secret: spec.secret,
            }),
        }
    }

    if diagnostics.is_empty() {
        Ok(resolved)
    } else {
        Err(diagnostics)
    }
}

/// Parse one canonical environment value using the shared lexical rules.
///
/// These rules intentionally reject runtime-specific conveniences: booleans are exactly
/// `true`/`false`, integers are canonical signed base-10 i64 values with no leading zeroes,
/// doubles use JSON-number syntax and must be finite, and arrays/maps use strict JSON roots.
/// JSON values use RFC/JSON whitespace rules; scalar booleans and numbers do not accept padding.
#[must_use]
pub fn parse_canonical_env_value(
    kind: EnvValueKind,
    raw: &str,
    allow_empty: bool,
) -> Option<Value> {
    match kind {
        EnvValueKind::String => {
            if !allow_empty && raw.is_empty() {
                None
            } else {
                Some(Value::String(raw.to_string()))
            }
        }
        EnvValueKind::Bool => match raw {
            "true" => Some(Value::Bool(true)),
            "false" => Some(Value::Bool(false)),
            _ => None,
        },
        EnvValueKind::Integer => parse_canonical_integer(raw).map(Value::from),
        EnvValueKind::Double => {
            if raw.trim() != raw {
                return None;
            }
            let value: Value = serde_json::from_str(raw).ok()?;
            let number = value.as_number()?;
            let parsed = number.as_f64()?;
            if parsed.is_finite() {
                Some(value)
            } else {
                None
            }
        }
        EnvValueKind::Json => serde_json::from_str(raw).ok(),
        EnvValueKind::Array => {
            let value: Value = serde_json::from_str(raw).ok()?;
            value.is_array().then_some(value)
        }
        EnvValueKind::Map => {
            let value: Value = serde_json::from_str(raw).ok()?;
            value.is_object().then_some(value)
        }
    }
}

fn parse_canonical_integer(raw: &str) -> Option<i64> {
    if raw.is_empty() || raw.trim() != raw {
        return None;
    }
    let digits = raw.strip_prefix('-').unwrap_or(raw);
    if digits.is_empty() {
        return None;
    }
    if digits.len() > 1 && digits.starts_with('0') {
        return None;
    }
    if !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    raw.parse::<i64>().ok()
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
    fn canonical_scalar_and_container_values_are_typed() {
        let cases = [
            (EnvValueKind::Bool, "true", Value::Bool(true)),
            (EnvValueKind::Integer, "-42", Value::from(-42)),
            (EnvValueKind::Double, "1.25e2", Value::from(125.0)),
            (
                EnvValueKind::Json,
                "{\"ok\":true}",
                serde_json::json!({"ok": true}),
            ),
            (EnvValueKind::Array, "[1,2]", serde_json::json!([1, 2])),
            (EnvValueKind::Map, "{\"x\":1}", serde_json::json!({"x": 1})),
        ];
        for (kind, raw, expected) in cases {
            assert_eq!(parse_canonical_env_value(kind, raw, false), Some(expected));
        }
    }

    #[test]
    fn noncanonical_values_fail_closed() {
        for raw in ["TRUE", "yes", "1", "0", " true", "false "] {
            assert_eq!(
                parse_canonical_env_value(EnvValueKind::Bool, raw, false),
                None
            );
        }
        for raw in ["01", "+1", "1.0", "1e3", "0x10", " 1", "1 "] {
            assert_eq!(
                parse_canonical_env_value(EnvValueKind::Integer, raw, false),
                None
            );
        }
        for raw in ["NaN", "Infinity", "+1.0", " 1.0", "1.0 "] {
            assert_eq!(
                parse_canonical_env_value(EnvValueKind::Double, raw, false),
                None
            );
        }
        assert_eq!(
            parse_canonical_env_value(EnvValueKind::Array, "{}", false),
            None
        );
        assert_eq!(
            parse_canonical_env_value(EnvValueKind::Map, "[]", false),
            None
        );
        assert_eq!(
            parse_canonical_env_value(EnvValueKind::Json, "{bad", false),
            None
        );
    }

    #[test]
    fn typed_bindings_collect_redacted_deterministic_errors() {
        let marker = "synthetic-secret-never-reflect";
        let env = EnvMap::from([
            ("BOOL_VALUE".to_string(), "YES".to_string()),
            ("SECRET_VALUE".to_string(), marker.to_string()),
        ]);
        let specs = vec![
            EnvBindingSpec::required("z.secret", "SECRET_VALUE", EnvValueKind::Integer)
                .secret(true),
            EnvBindingSpec::required("a.bool", "BOOL_VALUE", EnvValueKind::Bool),
            EnvBindingSpec::required("m.missing", "MISSING_VALUE", EnvValueKind::Double),
        ];
        let errors = resolve_typed_bindings(&env, &specs).unwrap_err();
        assert_eq!(errors.len(), 3);
        assert_eq!(errors[0].name, "BOOL_VALUE");
        assert_eq!(errors[0].code, ENV_PARSE);
        assert_eq!(errors[1].name, "MISSING_VALUE");
        assert_eq!(errors[1].code, ENV_MISSING);
        assert_eq!(errors[2].name, "SECRET_VALUE");
        assert!(errors[2].secret);
        let rendered = format!("{errors:?}");
        assert!(!rendered.contains(marker));
    }

    #[test]
    fn optional_values_are_checked_when_present() {
        let spec = EnvBindingSpec::optional("feature.count", "COUNT", EnvValueKind::Integer);
        assert_eq!(
            resolve_typed_bindings(&EnvMap::new(), &[spec.clone()]),
            Ok(BTreeMap::new())
        );
        let invalid = EnvMap::from([("COUNT".to_string(), "1.5".to_string())]);
        let errors = resolve_typed_bindings(&invalid, &[spec]).unwrap_err();
        assert_eq!(errors[0].code, ENV_PARSE);
    }

    #[test]
    fn source_does_not_write_process_environment() {
        const SRC: &str = include_str!("env_map.rs");
        let production = SRC.split("#[cfg(test)]").next().unwrap_or(SRC);
        assert!(!production.contains("set_var"));
    }
}
