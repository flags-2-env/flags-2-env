//! Runtime loading for the common envelope shared by domain TOML configuration files.
//!
//! This module intentionally does not know chat/forms/legal/rate-limit/etc. semantics. Those
//! remain owned by each domain's independent TypeSpec and hand-authored JSON Schema. It reads only
//! the common root `version`, `[flags2env]`, and `[[env]]` declarations so an executable can prove
//! the committed domain file actually controls its flags-2-env contract and RuntimeConfig inputs.

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt, fs,
    path::Path,
};

use super::{resolve_bindings, EnvMap};

/// Maximum domain configuration source accepted by the generic runtime envelope loader.
pub const MAX_DOMAIN_CONFIG_BYTES: usize = 64 * 1024;

/// The only flags-2-env precedence contract supported by this runtime helper.
pub const ARGV_OVER_ENV: &str = "argv-over-env";

/// Canonical root flags-2-env contract filename.
pub const CLI_FLAGS_CONTRACT: &str = ".cli-flags.toml";

/// Common flags-2-env metadata embedded in a domain TOML file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flags2EnvEnvelope {
    contract: String,
    require_audit: bool,
    precedence: String,
}

impl Flags2EnvEnvelope {
    /// Relative flags-2-env contract path selected by the domain config.
    #[must_use]
    pub fn contract(&self) -> &str {
        &self.contract
    }

    /// Whether startup must audit the flags-2-env contract before parsing argv.
    #[must_use]
    pub const fn require_audit(&self) -> bool {
        self.require_audit
    }

    /// Declared precedence rule.
    #[must_use]
    pub fn precedence(&self) -> &str {
        &self.precedence
    }
}

/// One symbolic RuntimeConfig declaration from `[[env]]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DomainEnvBinding {
    /// Symbolic domain field name.
    pub name: String,
    /// Portable environment-key name.
    pub key: String,
    /// Domain-declared scalar/container kind; final coercion still belongs to `.cli-flags.toml`.
    pub kind: String,
    /// Whether runtime startup requires a value after defaults and flags-2-env precedence.
    pub required: bool,
    /// Whether this value is secret. Secret defaults are forbidden.
    pub secret: bool,
    /// Optional non-secret default, applied below environment/argv values.
    pub default: Option<String>,
}

/// Admitted common runtime envelope extracted from a domain TOML file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DomainConfigEnvelope {
    version: u32,
    flags2env: Flags2EnvEnvelope,
    env: Vec<DomainEnvBinding>,
}

impl DomainConfigEnvelope {
    /// Parse the common envelope from TOML source that is independently validated by the domain.
    ///
    /// Domain-specific sections are deliberately ignored. This parser is not a replacement for
    /// TypeSpec/JSON Schema admission; it exists so runtime executables consume the committed file.
    ///
    /// # Errors
    /// Returns a redacted [`DomainConfigError`] for malformed or unsafe common-envelope input.
    pub fn parse(source: &str) -> Result<Self, DomainConfigError> {
        if source.len() > MAX_DOMAIN_CONFIG_BYTES {
            return Err(DomainConfigError::TooLarge);
        }
        if source.as_bytes().contains(&0) {
            return Err(DomainConfigError::InvalidDocument);
        }

        let mut root_version = None;
        let mut flags = FlagsBuilder::default();
        let mut env_builders = Vec::<EnvBuilder>::new();
        let mut section = Section::Root;

        for raw_line in source.lines() {
            let line = strip_comment(raw_line)?.trim();
            if line.is_empty() {
                continue;
            }
            if line == "[flags2env]" {
                section = Section::Flags2Env;
                continue;
            }
            if line == "[[env]]" {
                env_builders.push(EnvBuilder::default());
                section = Section::Env(env_builders.len() - 1);
                continue;
            }
            if line.starts_with('[') && line.ends_with(']') {
                section = Section::Other;
                continue;
            }

            let Some((raw_key, raw_value)) = line.split_once('=') else {
                return Err(DomainConfigError::InvalidDocument);
            };
            let key = raw_key.trim();
            let value = raw_value.trim();
            match section {
                Section::Root if key == "version" => {
                    set_once(&mut root_version, parse_u32(value)?)?;
                }
                Section::Flags2Env => flags.assign(key, value)?,
                Section::Env(index) => env_builders[index].assign(key, value)?,
                Section::Root | Section::Other => {}
            }
        }

        let version = root_version.ok_or(DomainConfigError::InvalidDocument)?;
        if version != 1 {
            return Err(DomainConfigError::UnsupportedVersion);
        }
        let flags2env = flags.finish()?;
        if flags2env.contract != CLI_FLAGS_CONTRACT
            || !flags2env.require_audit
            || flags2env.precedence != ARGV_OVER_ENV
        {
            return Err(DomainConfigError::InvalidFlags2EnvContract);
        }

        let env = env_builders
            .into_iter()
            .map(EnvBuilder::finish)
            .collect::<Result<Vec<_>, _>>()?;
        validate_bindings(&env)?;

        Ok(Self {
            version,
            flags2env,
            env,
        })
    }

    /// Safely read and parse a domain TOML file from a repository/process working directory.
    ///
    /// Symlinks and non-regular files are rejected. The source is size bounded and must be UTF-8.
    ///
    /// # Errors
    /// Returns a redacted [`DomainConfigError`]. The path and file contents are not reflected.
    pub fn read(path: impl AsRef<Path>) -> Result<Self, DomainConfigError> {
        let path = path.as_ref();
        let metadata = fs::symlink_metadata(path).map_err(|_| DomainConfigError::ReadFailed)?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(DomainConfigError::UnsafeFile);
        }
        if metadata.len() > MAX_DOMAIN_CONFIG_BYTES as u64 {
            return Err(DomainConfigError::TooLarge);
        }
        let bytes = fs::read(path).map_err(|_| DomainConfigError::ReadFailed)?;
        let source = std::str::from_utf8(&bytes).map_err(|_| DomainConfigError::InvalidUtf8)?;
        Self::parse(source)
    }

    /// Common envelope version.
    #[must_use]
    pub const fn version(&self) -> u32 {
        self.version
    }

    /// Flags-2-env startup metadata selected by the domain config.
    #[must_use]
    pub const fn flags2env(&self) -> &Flags2EnvEnvelope {
        &self.flags2env
    }

    /// Environment declarations from the domain config.
    #[must_use]
    pub fn env(&self) -> &[DomainEnvBinding] {
        &self.env
    }

    /// Apply non-secret domain defaults below the already-final environment/argv snapshot and
    /// resolve symbolic names through the common flags-2-env binding seam.
    ///
    /// The caller should pass the immutable map after normal flags-2-env precedence has been
    /// applied. Existing values always win over domain defaults. Optional declarations without a
    /// value/default are omitted. Required missing values fail closed.
    ///
    /// # Errors
    /// Returns a redacted [`DomainConfigError`] without reflecting runtime values.
    pub fn resolve(&self, final_env: &EnvMap) -> Result<ResolvedDomainConfig, DomainConfigError> {
        let mut effective_env = final_env.clone();
        let mut declarations = BTreeMap::<String, String>::new();

        for binding in &self.env {
            let present = effective_env
                .get(&binding.key)
                .is_some_and(|value| !value.trim().is_empty());
            if !present {
                if let Some(default) = &binding.default {
                    effective_env.insert(binding.key.clone(), default.clone());
                } else if binding.required {
                    return Err(DomainConfigError::MissingRequired {
                        field: binding.name.clone(),
                    });
                } else {
                    continue;
                }
            }
            declarations.insert(binding.name.clone(), binding.key.clone());
        }

        let values = resolve_bindings(&effective_env, &declarations).map_err(|error| {
            DomainConfigError::Binding {
                code: error.code(),
            }
        })?;
        Ok(ResolvedDomainConfig {
            effective_env,
            values,
        })
    }
}

/// Runtime result after domain defaults and symbolic bindings are applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedDomainConfig {
    effective_env: EnvMap,
    values: BTreeMap<String, String>,
}

impl ResolvedDomainConfig {
    /// Environment-key map suitable for the existing flags-2-env coercion step.
    #[must_use]
    pub const fn effective_env(&self) -> &EnvMap {
        &self.effective_env
    }

    /// Resolved values keyed by symbolic domain field name.
    #[must_use]
    pub const fn values(&self) -> &BTreeMap<String, String> {
        &self.values
    }

    /// Resolve one symbolic field without re-reading process environment.
    #[must_use]
    pub fn value(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }
}

/// Redacted domain-envelope failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DomainConfigError {
    /// Source is larger than the runtime admission cap.
    TooLarge,
    /// File could not be read.
    ReadFailed,
    /// File is a symlink or not a regular file.
    UnsafeFile,
    /// Source is not UTF-8.
    InvalidUtf8,
    /// Common TOML envelope is malformed or incomplete.
    InvalidDocument,
    /// Common envelope version is unsupported.
    UnsupportedVersion,
    /// `[flags2env]` does not select audited root `.cli-flags.toml` with argv-over-env precedence.
    InvalidFlags2EnvContract,
    /// One `[[env]]` declaration is malformed.
    InvalidEnvBinding { field: Option<String> },
    /// Secret bindings may not carry plaintext defaults.
    SecretDefault { field: String },
    /// Duplicate symbolic field or environment-key declaration.
    DuplicateBinding { field: String },
    /// Required runtime value is absent after flags/env/default resolution.
    MissingRequired { field: String },
    /// Common immutable binding resolution failed.
    Binding { code: &'static str },
}

impl fmt::Display for DomainConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLarge => formatter.write_str("domain config exceeds the runtime size limit"),
            Self::ReadFailed => formatter.write_str("domain config could not be read"),
            Self::UnsafeFile => formatter.write_str("domain config must be a regular non-symlink file"),
            Self::InvalidUtf8 => formatter.write_str("domain config must be UTF-8"),
            Self::InvalidDocument => formatter.write_str("domain config common envelope is invalid"),
            Self::UnsupportedVersion => formatter.write_str("domain config version is unsupported"),
            Self::InvalidFlags2EnvContract => formatter.write_str(
                "domain config must select audited .cli-flags.toml with argv-over-env precedence",
            ),
            Self::InvalidEnvBinding { field: Some(field) } => {
                write!(formatter, "domain config env declaration for {field} is invalid")
            }
            Self::InvalidEnvBinding { field: None } => {
                formatter.write_str("domain config env declaration is invalid")
            }
            Self::SecretDefault { field } => {
                write!(formatter, "domain config secret declaration for {field} may not have a default")
            }
            Self::DuplicateBinding { field } => {
                write!(formatter, "domain config declaration for {field} is duplicated or aliased")
            }
            Self::MissingRequired { field } => {
                write!(formatter, "domain config required binding {field} is missing")
            }
            Self::Binding { code } => write!(formatter, "domain config RuntimeConfig binding failed: {code}"),
        }
    }
}

impl std::error::Error for DomainConfigError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Section {
    Root,
    Flags2Env,
    Env(usize),
    Other,
}

#[derive(Default)]
struct FlagsBuilder {
    contract: Option<String>,
    require_audit: Option<bool>,
    precedence: Option<String>,
}

impl FlagsBuilder {
    fn assign(&mut self, key: &str, value: &str) -> Result<(), DomainConfigError> {
        match key {
            "contract" => set_once(&mut self.contract, parse_string(value)?),
            "require_audit" => set_once(&mut self.require_audit, parse_bool(value)?),
            "precedence" => set_once(&mut self.precedence, parse_string(value)?),
            _ => Ok(()),
        }
    }

    fn finish(self) -> Result<Flags2EnvEnvelope, DomainConfigError> {
        Ok(Flags2EnvEnvelope {
            contract: self.contract.ok_or(DomainConfigError::InvalidDocument)?,
            require_audit: self
                .require_audit
                .ok_or(DomainConfigError::InvalidDocument)?,
            precedence: self
                .precedence
                .ok_or(DomainConfigError::InvalidDocument)?,
        })
    }
}

#[derive(Default)]
struct EnvBuilder {
    name: Option<String>,
    key: Option<String>,
    kind: Option<String>,
    required: Option<bool>,
    secret: Option<bool>,
    default: Option<String>,
}

impl EnvBuilder {
    fn assign(&mut self, key: &str, value: &str) -> Result<(), DomainConfigError> {
        match key {
            "name" => set_once(&mut self.name, parse_string(value)?),
            "key" => set_once(&mut self.key, parse_string(value)?),
            "kind" => set_once(&mut self.kind, parse_string(value)?),
            "required" => set_once(&mut self.required, parse_bool(value)?),
            "secret" => set_once(&mut self.secret, parse_bool(value)?),
            "default" => set_once(&mut self.default, parse_string(value)?),
            _ => Ok(()),
        }
    }

    fn finish(self) -> Result<DomainEnvBinding, DomainConfigError> {
        let name = self.name.ok_or(DomainConfigError::InvalidEnvBinding { field: None })?;
        let binding = DomainEnvBinding {
            key: self.key.ok_or_else(|| DomainConfigError::InvalidEnvBinding {
                field: Some(name.clone()),
            })?,
            kind: self.kind.ok_or_else(|| DomainConfigError::InvalidEnvBinding {
                field: Some(name.clone()),
            })?,
            required: self.required.ok_or_else(|| DomainConfigError::InvalidEnvBinding {
                field: Some(name.clone()),
            })?,
            secret: self.secret.ok_or_else(|| DomainConfigError::InvalidEnvBinding {
                field: Some(name.clone()),
            })?,
            default: self.default,
            name,
        };
        if binding.secret && binding.default.is_some() {
            return Err(DomainConfigError::SecretDefault {
                field: binding.name.clone(),
            });
        }
        Ok(binding)
    }
}

fn validate_bindings(bindings: &[DomainEnvBinding]) -> Result<(), DomainConfigError> {
    let mut names = BTreeSet::new();
    let mut keys = BTreeSet::new();
    for binding in bindings {
        if !valid_symbolic_name(&binding.name) || !valid_env_key(&binding.key) || binding.kind.is_empty() {
            return Err(DomainConfigError::InvalidEnvBinding {
                field: Some(binding.name.clone()),
            });
        }
        if !names.insert(binding.name.as_str()) || !keys.insert(binding.key.as_str()) {
            return Err(DomainConfigError::DuplicateBinding {
                field: binding.name.clone(),
            });
        }
    }
    Ok(())
}

fn valid_symbolic_name(value: &str) -> bool {
    let mut bytes = value.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    first.is_ascii_lowercase()
        && value.len() <= 64
        && bytes.all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

fn valid_env_key(value: &str) -> bool {
    let Some(first) = value.bytes().next() else {
        return false;
    };
    (first.is_ascii_uppercase() || first == b'_')
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
}

fn set_once<T>(slot: &mut Option<T>, value: T) -> Result<(), DomainConfigError> {
    if slot.is_some() {
        return Err(DomainConfigError::InvalidDocument);
    }
    *slot = Some(value);
    Ok(())
}

fn parse_u32(value: &str) -> Result<u32, DomainConfigError> {
    value
        .parse::<u32>()
        .map_err(|_| DomainConfigError::InvalidDocument)
}

fn parse_bool(value: &str) -> Result<bool, DomainConfigError> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(DomainConfigError::InvalidDocument),
    }
}

fn parse_string(value: &str) -> Result<String, DomainConfigError> {
    let inner = value
        .strip_prefix('"')
        .and_then(|candidate| candidate.strip_suffix('"'))
        .ok_or(DomainConfigError::InvalidDocument)?;
    let mut output = String::with_capacity(inner.len());
    let mut escaped = false;
    for character in inner.chars() {
        if escaped {
            output.push(match character {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                _ => return Err(DomainConfigError::InvalidDocument),
            });
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character.is_control() {
            return Err(DomainConfigError::InvalidDocument);
        } else {
            output.push(character);
        }
    }
    if escaped {
        return Err(DomainConfigError::InvalidDocument);
    }
    Ok(output)
}

fn strip_comment(line: &str) -> Result<&str, DomainConfigError> {
    let bytes = line.as_bytes();
    let mut quoted = false;
    let mut escaped = false;
    for (index, byte) in bytes.iter().copied().enumerate() {
        if escaped {
            escaped = false;
            continue;
        }
        if quoted && byte == b'\\' {
            escaped = true;
            continue;
        }
        if byte == b'"' {
            quoted = !quoted;
            continue;
        }
        if !quoted && byte == b'#' {
            return Ok(&line[..index]);
        }
    }
    if quoted || escaped {
        Err(DomainConfigError::InvalidDocument)
    } else {
        Ok(line)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = r#"
version = 1
mode = "hybrid"
strict = true

[flags2env]
contract = ".cli-flags.toml"
require_audit = true
precedence = "argv-over-env"

[[env]]
name = "api_base_url"
key = "ORES_CHAT_API_BASE_URL"
kind = "url"
required = false
secret = false
default = "http://127.0.0.1:8080"
description = "client API"

[[env]]
name = "database_url"
key = "DATABASE_URL"
kind = "url"
required = true
secret = true

[client]
enabled = true
api_base_url_binding = "api_base_url"

[server]
enabled = true
database_url_binding = "database_url"
"#;

    #[test]
    fn common_envelope_drives_contract_and_runtime_defaults() {
        let config = DomainConfigEnvelope::parse(SOURCE).unwrap();
        assert_eq!(config.version(), 1);
        assert_eq!(config.flags2env().contract(), CLI_FLAGS_CONTRACT);
        assert!(config.flags2env().require_audit());
        assert_eq!(config.flags2env().precedence(), ARGV_OVER_ENV);

        let env = EnvMap::from([(
            "DATABASE_URL".to_string(),
            "postgres://runtime-only.invalid/chat".to_string(),
        )]);
        let resolved = config.resolve(&env).unwrap();
        assert_eq!(
            resolved.value("api_base_url"),
            Some("http://127.0.0.1:8080")
        );
        assert_eq!(
            resolved.value("database_url"),
            Some("postgres://runtime-only.invalid/chat")
        );
        assert_eq!(
            resolved.effective_env().get("ORES_CHAT_API_BASE_URL").map(String::as_str),
            Some("http://127.0.0.1:8080")
        );
    }

    #[test]
    fn final_env_beats_domain_default() {
        let config = DomainConfigEnvelope::parse(SOURCE).unwrap();
        let env = EnvMap::from([
            (
                "DATABASE_URL".to_string(),
                "postgres://runtime.invalid/chat".to_string(),
            ),
            (
                "ORES_CHAT_API_BASE_URL".to_string(),
                "https://api.example.test".to_string(),
            ),
        ]);
        let resolved = config.resolve(&env).unwrap();
        assert_eq!(resolved.value("api_base_url"), Some("https://api.example.test"));
    }

    #[test]
    fn missing_required_secret_fails_without_reflecting_other_values() {
        let config = DomainConfigEnvelope::parse(SOURCE).unwrap();
        let marker = "synthetic-secret-never-reflect";
        let env = EnvMap::from([("UNRELATED".to_string(), marker.to_string())]);
        let error = config.resolve(&env).unwrap_err();
        assert_eq!(
            error,
            DomainConfigError::MissingRequired {
                field: "database_url".to_string(),
            }
        );
        let rendered = format!("{error:?} {error}");
        assert!(!rendered.contains(marker));
    }

    #[test]
    fn secret_defaults_and_noncanonical_flags_contract_fail_closed() {
        let secret_default = SOURCE.replace(
            "secret = true\n\n[client]",
            "secret = true\ndefault = \"plaintext\"\n\n[client]",
        );
        assert!(matches!(
            DomainConfigEnvelope::parse(&secret_default),
            Err(DomainConfigError::SecretDefault { .. })
        ));

        let wrong_contract = SOURCE.replace(
            "contract = \".cli-flags.toml\"",
            "contract = \"config/other.toml\"",
        );
        assert_eq!(
            DomainConfigEnvelope::parse(&wrong_contract),
            Err(DomainConfigError::InvalidFlags2EnvContract)
        );
    }

    #[test]
    fn duplicate_env_aliases_fail_closed() {
        let duplicate = SOURCE.replace(
            "key = \"DATABASE_URL\"",
            "key = \"ORES_CHAT_API_BASE_URL\"",
        );
        assert!(matches!(
            DomainConfigEnvelope::parse(&duplicate),
            Err(DomainConfigError::DuplicateBinding { .. })
        ));
    }

    #[cfg(unix)]
    #[test]
    fn read_rejects_symlinked_domain_config() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let real = directory.path().join("real.toml");
        let link = directory.path().join(".ores-chat.toml");
        fs::write(&real, SOURCE).unwrap();
        symlink(&real, &link).unwrap();
        assert_eq!(
            DomainConfigEnvelope::read(&link),
            Err(DomainConfigError::UnsafeFile)
        );
    }
}
