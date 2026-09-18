pub mod bundled;
pub mod env_map;

pub use bundled::BundledFlags2Env;
pub use env_map::{
    cli_overrides, current_env_map, env_map_from_argv, env_value, get_env_map, process_argv,
    process_env_map, EnvMap,
};

#[cfg(any(test, kani))]
mod formal_model;

use libloading::{Library, Symbol};
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::fmt;
use std::os::raw::c_char;

type ParseFn = unsafe extern "C" fn(*const c_char, *const c_char) -> *mut c_char;
type ParseDefaultFn = unsafe extern "C" fn(*const c_char) -> *mut c_char;
type ParseProcessFn = unsafe extern "C" fn(*const c_char) -> *mut c_char;
type ParseProcessDefaultFn = unsafe extern "C" fn() -> *mut c_char;
type FreeFn = unsafe extern "C" fn(*mut c_char);

/// Failure returned by [`Flags2Env::coerce`] and
/// [`BundledFlags2Env::coerce`].
#[derive(Debug)]
pub enum CoercionError {
    /// The input value could not be encoded as JSON for the native parser.
    Serialize(serde_json::Error),
    /// A path passed across the native boundary contained an interior NUL.
    InputContainsNul(std::ffi::NulError),
    /// The dynamically loaded library does not provide the required coercion
    /// symbols or otherwise failed symbol lookup.
    DynamicLibrary(libloading::Error),
    /// The native coercion function returned no report.
    NativeUnavailable,
    /// The native coercion report did not follow the flags2env report schema.
    InvalidReport(String),
    /// One or more declared values failed schema coercion.
    Validation { errors: Vec<String> },
    /// Coercion succeeded, but the resulting object did not match the caller's
    /// requested Rust type.
    Deserialize(serde_json::Error),
}

impl CoercionError {
    /// Returns schema validation messages when this is a
    /// [`CoercionError::Validation`] failure.
    pub fn validation_errors(&self) -> Option<&[String]> {
        match self {
            Self::Validation { errors } => Some(errors),
            _ => None,
        }
    }
}

impl fmt::Display for CoercionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Serialize(error) => {
                write!(formatter, "flags2env could not serialize values: {error}")
            }
            Self::InputContainsNul(error) => {
                write!(
                    formatter,
                    "flags2env input contains an interior NUL byte: {error}"
                )
            }
            Self::DynamicLibrary(error) => {
                write!(
                    formatter,
                    "flags2env could not load the coercion function: {error}"
                )
            }
            Self::NativeUnavailable => {
                write!(formatter, "flags2env coercion returned no result")
            }
            Self::InvalidReport(message) => {
                write!(
                    formatter,
                    "flags2env returned an invalid coercion report: {message}"
                )
            }
            Self::Validation { errors } => {
                write!(
                    formatter,
                    "flags2env could not coerce config: {}",
                    errors.join("; ")
                )
            }
            Self::Deserialize(error) => {
                write!(
                    formatter,
                    "flags2env coerced values do not match the requested Rust type: {error}"
                )
            }
        }
    }
}

impl std::error::Error for CoercionError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Serialize(error) | Self::Deserialize(error) => Some(error),
            Self::InputContainsNul(error) => Some(error),
            Self::DynamicLibrary(error) => Some(error),
            Self::NativeUnavailable | Self::InvalidReport(_) | Self::Validation { .. } => None,
        }
    }
}

impl From<std::ffi::NulError> for CoercionError {
    fn from(error: std::ffi::NulError) -> Self {
        Self::InputContainsNul(error)
    }
}

impl From<libloading::Error> for CoercionError {
    fn from(error: libloading::Error) -> Self {
        Self::DynamicLibrary(error)
    }
}

/// Structured parse result: each channel is returned separately instead of
/// packed into env keys, so nothing can be shadowed by real environment
/// variables. `flags` is the same fully-resolved map `parse` returns;
/// `provided_flags` contains only argv-derived values and command markers, so
/// it can safely be merged over the process environment before coercion.
///
/// `dotenv` and `dotenv_overrides` split the `./.env` values by where they
/// belong relative to the caller's own environment snapshot, which is what
/// keeps per-flag `dotenv_override` expressible as a flat merge: apply
/// `dotenv`, then the environment, then `dotenv_overrides`, then
/// `provided_flags`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StructuredParse {
    pub flags: HashMap<String, String>,
    pub provided_flags: HashMap<String, String>,
    pub dotenv: HashMap<String, String>,
    pub dotenv_overrides: HashMap<String, String>,
    /// Resolved source order for each key that deviates from the default.
    pub source_order: HashMap<String, Vec<String>>,
    pub command: String,
    pub subcommands: Vec<String>,
    pub extras: Vec<String>,
    pub unknown_options: Vec<String>,
    pub errors: Vec<String>,
}

/// The `[commands.*]` path selected by argv, independent of the env map.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ResolvedCommands {
    pub path: Vec<String>,
    pub label: String,
}

/// A parsed `.cli-flags.toml` contract audit report.
///
/// Findings name config tables, keys and flag names only — never a value read
/// from argv, the environment, or a `.env` file — so a service that refuses to
/// start may log the whole report without leaking a secret.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AuditReport {
    /// True only when the auditor reported zero error-level findings.
    pub ok: bool,
    /// Error-level findings. Each one on its own blocks the config.
    pub errors: Vec<String>,
    /// Advisory findings that do not block the config.
    pub warnings: Vec<String>,
}

impl AuditReport {
    /// True when nothing error-level was found.
    pub fn passed(&self) -> bool {
        self.ok && self.errors.is_empty()
    }

    /// Every error-level finding on one line, for an operator log.
    pub fn error_summary(&self) -> String {
        if self.errors.is_empty() {
            "the auditor reported no reason".to_owned()
        } else {
            self.errors.join("; ")
        }
    }
}

/// The error [`BundledFlags2Env::audit_config`] returns when the contract is
/// rejected.
///
/// It carries the full [`AuditReport`], so a caller can print
/// [`AuditReport::error_summary`] or inspect the findings individually instead
/// of collapsing the failure to an opaque status code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditFailed {
    pub report: AuditReport,
}

impl fmt::Display for AuditFailed {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "flags2env contract audit failed: {}",
            self.report.error_summary()
        )
    }
}

impl std::error::Error for AuditFailed {}

fn json_string_vec(value: Option<&serde_json::Value>) -> Vec<String> {
    value
        .and_then(|value| value.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

fn json_string_map(value: Option<&serde_json::Value>) -> HashMap<String, String> {
    value
        .and_then(|value| value.as_object())
        .map(|object| {
            object
                .iter()
                .filter_map(|(key, item)| item.as_str().map(|text| (key.clone(), text.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

fn json_string_vec_map(value: Option<&serde_json::Value>) -> HashMap<String, Vec<String>> {
    value
        .and_then(|value| value.as_object())
        .map(|object| {
            object
                .iter()
                .map(|(key, item)| (key.clone(), json_string_vec(Some(item))))
                .collect()
        })
        .unwrap_or_default()
}

fn required_json_string_map(
    value: Option<&serde_json::Value>,
    error: &'static str,
) -> Result<HashMap<String, String>, &'static str> {
    value
        .and_then(serde_json::Value::as_object)
        .ok_or(error)?
        .iter()
        .map(|(key, item)| {
            item.as_str()
                .map(|text| (key.clone(), text.to_string()))
                .ok_or(error)
        })
        .collect()
}

fn coercion_input_json<V>(values: &V) -> Result<CString, CoercionError>
where
    V: Serialize + ?Sized,
{
    let values_json = serde_json::to_string(values).map_err(CoercionError::Serialize)?;
    Ok(CString::new(values_json)?)
}

fn decode_coercion_report<T>(raw: &str) -> Result<T, CoercionError>
where
    T: DeserializeOwned,
{
    let report: serde_json::Value = serde_json::from_str(raw)
        .map_err(|error| CoercionError::InvalidReport(error.to_string()))?;
    let object = report
        .as_object()
        .ok_or_else(|| CoercionError::InvalidReport("expected a JSON object".to_string()))?;
    match object.get("ok").and_then(serde_json::Value::as_bool) {
        Some(true) => {
            let value = object.get("value").cloned().ok_or_else(|| {
                CoercionError::InvalidReport("successful report has no value".to_string())
            })?;
            serde_json::from_value(value).map_err(CoercionError::Deserialize)
        }
        Some(false) => {
            let errors = object
                .get("errors")
                .and_then(serde_json::Value::as_array)
                .ok_or_else(|| {
                    CoercionError::InvalidReport("failed report has no errors array".to_string())
                })?
                .iter()
                .map(|error| {
                    error.as_str().map(String::from).ok_or_else(|| {
                        CoercionError::InvalidReport(
                            "failed report contains a non-string error".to_string(),
                        )
                    })
                })
                .collect::<Result<Vec<_>, _>>()?;
            if errors.is_empty() {
                return Err(CoercionError::InvalidReport(
                    "failed report has an empty errors array".to_string(),
                ));
            }
            Err(CoercionError::Validation { errors })
        }
        None => Err(CoercionError::InvalidReport(
            "report has no boolean ok field".to_string(),
        )),
    }
}

/// Dynamically loaded flags2env backend.
///
/// Prefer [`BundledFlags2Env`] for self-contained CLI/server binaries and
/// minimal containers. Keep this type for callers that intentionally select a
/// separately installed shared library at runtime.
pub struct Flags2Env {
    library: Library,
}

impl Flags2Env {
    /// Load a flags2env shared library from `path`, or from the platform default
    /// library name when `path` is absent.
    ///
    /// # Safety
    ///
    /// The selected library must be a trusted, ABI-compatible flags2env build
    /// exporting the expected `f2e_*` symbols with the ownership contract from
    /// `parser.h`. Loading an untrusted or incompatible dynamic library can run
    /// arbitrary initialization code or cause undefined behavior when symbols
    /// are called. Keep the returned value alive while any loaded symbol is in
    /// use; this type does so internally for all public methods.
    pub unsafe fn load(path: Option<&str>) -> Result<Self, libloading::Error> {
        Ok(Self {
            library: Library::new(path.unwrap_or(default_library_name()))?,
        })
    }

    pub fn parse(
        &self,
        argv: &[String],
        config_path: Option<&str>,
    ) -> Result<HashMap<String, String>, Box<dyn std::error::Error>> {
        let argv_json = CString::new(serde_json::to_string(argv)?)?;

        unsafe {
            let free: Symbol<FreeFn> = self.library.get(b"f2e_free")?;
            let result = if let Some(config_path) = config_path {
                let config_path = CString::new(config_path)?;
                let parse: Symbol<ParseFn> = self.library.get(b"f2e_parse_json_argv_from_file")?;
                parse(config_path.as_ptr(), argv_json.as_ptr())
            } else {
                let parse: Symbol<ParseDefaultFn> = self.library.get(b"f2e_parse_json_argv")?;
                parse(argv_json.as_ptr())
            };
            if result.is_null() {
                return Ok(HashMap::new());
            }
            let raw = CStr::from_ptr(result).to_string_lossy().to_string();
            free(result);
            Ok(serde_json::from_str(&raw)?)
        }
    }

    pub fn parse_process(
        &self,
        config_path: Option<&str>,
    ) -> Result<HashMap<String, String>, Box<dyn std::error::Error>> {
        unsafe {
            let free: Symbol<FreeFn> = self.library.get(b"f2e_free")?;
            let result = if let Some(config_path) = config_path {
                let config_path = CString::new(config_path)?;
                let parse: Symbol<ParseProcessFn> =
                    self.library.get(b"f2e_parse_process_from_file")?;
                parse(config_path.as_ptr())
            } else {
                let parse: Symbol<ParseProcessDefaultFn> =
                    self.library.get(b"f2e_parse_process")?;
                parse()
            };
            if result.is_null() {
                return Ok(HashMap::new());
            }
            let raw = CStr::from_ptr(result).to_string_lossy().to_string();
            free(result);
            Ok(serde_json::from_str(&raw)?)
        }
    }

    /// Coerce declared environment values according to `.cli-flags.toml` and
    /// deserialize the result into `T`.
    ///
    /// `values` may be a parsed flags map, a merged environment/flags map, or
    /// any other serializable object. Undeclared keys are ignored by the native
    /// coercion layer. Schema defaults are applied, declared scalar and
    /// container types are converted, and all schema conversion failures are
    /// returned together as [`CoercionError::Validation`].
    pub fn coerce<T, V>(&self, values: &V, config_path: Option<&str>) -> Result<T, CoercionError>
    where
        T: DeserializeOwned,
        V: Serialize + ?Sized,
    {
        let values_json = coercion_input_json(values)?;
        unsafe {
            let free: Symbol<FreeFn> = self.library.get(b"f2e_free")?;
            let result = if let Some(config_path) = config_path {
                let config_path = CString::new(config_path)?;
                let coerce: Symbol<ParseFn> = self.library.get(b"f2e_coerce_json_from_file")?;
                coerce(config_path.as_ptr(), values_json.as_ptr())
            } else {
                let coerce: Symbol<ParseDefaultFn> = self.library.get(b"f2e_coerce_json")?;
                coerce(values_json.as_ptr())
            };
            if result.is_null() {
                return Err(CoercionError::NativeUnavailable);
            }
            let raw = CStr::from_ptr(result).to_string_lossy().into_owned();
            free(result);
            decode_coercion_report(&raw)
        }
    }

    fn call_json_argv(
        &self,
        symbol: &[u8],
        symbol_from_file: &[u8],
        argv: &[String],
        config_path: Option<&str>,
    ) -> Result<Option<String>, Box<dyn std::error::Error>> {
        let argv_json = CString::new(serde_json::to_string(argv)?)?;
        unsafe {
            let free: Symbol<FreeFn> = self.library.get(b"f2e_free")?;
            let result = if let Some(config_path) = config_path {
                let config_path = CString::new(config_path)?;
                let call: Symbol<ParseFn> = self.library.get(symbol_from_file)?;
                call(config_path.as_ptr(), argv_json.as_ptr())
            } else {
                let call: Symbol<ParseDefaultFn> = self.library.get(symbol)?;
                call(argv_json.as_ptr())
            };
            if result.is_null() {
                return Ok(None);
            }
            let raw = CStr::from_ptr(result).to_string_lossy().to_string();
            free(result);
            Ok(Some(raw))
        }
    }

    /// Structured parse: `{flags, provided_flags, command, subcommands,
    /// extras, unknown_options, errors}` as separate channels
    /// (dashdash-style).
    /// Extras are the operand tokens: positionals after the last matched
    /// command (including tokens after a bare `--`); with no command matched,
    /// every positional except argv\[0\].
    pub fn parse_structured(
        &self,
        argv: &[String],
        config_path: Option<&str>,
    ) -> Result<StructuredParse, Box<dyn std::error::Error>> {
        let raw = self
            .call_json_argv(
                b"f2e_parse_structured_json_argv",
                b"f2e_parse_structured_json_argv_from_file",
                argv,
                config_path,
            )?
            .ok_or("flags2env could not parse argv; check the config path")?;
        let report: serde_json::Value = serde_json::from_str(&raw)?;
        Ok(StructuredParse {
            flags: json_string_map(report.get("flags")),
            provided_flags: required_json_string_map(
                report.get("providedFlags"),
                "loaded flags2env library does not support argv-only overrides",
            )?,
            dotenv: json_string_map(report.get("dotenv")),
            dotenv_overrides: json_string_map(report.get("dotenvOverrides")),
            source_order: json_string_vec_map(report.get("sourceOrder")),
            command: report
                .get("command")
                .and_then(|value| value.as_str())
                .unwrap_or_default()
                .to_string(),
            subcommands: json_string_vec(report.get("subcommands")),
            extras: json_string_vec(report.get("extras")),
            unknown_options: json_string_vec(report.get("unknownOptions")),
            errors: json_string_vec(report.get("errors")),
        })
    }

    /// Resolves just the `[commands.*]` path selected by argv.
    pub fn resolve_commands(
        &self,
        argv: &[String],
        config_path: Option<&str>,
    ) -> Result<ResolvedCommands, Box<dyn std::error::Error>> {
        let raw = self
            .call_json_argv(
                b"f2e_resolve_commands_json_argv",
                b"f2e_resolve_commands_json_argv_from_file",
                argv,
                config_path,
            )?
            .ok_or("flags2env could not resolve commands; check the config path")?;
        let report: serde_json::Value = serde_json::from_str(&raw)?;
        Ok(ResolvedCommands {
            path: json_string_vec(report.get("path")),
            label: report
                .get("label")
                .and_then(|value| value.as_str())
                .unwrap_or_default()
                .to_string(),
        })
    }

    pub fn apply(
        &self,
        env_map: &mut HashMap<String, String>,
        argv: &[String],
    ) -> Result<(), Box<dyn std::error::Error>> {
        env_map.extend(self.parse(argv, None)?);
        Ok(())
    }

    pub fn apply_process(
        &self,
        env_map: &mut HashMap<String, String>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        env_map.extend(self.parse_process(None)?);
        Ok(())
    }
}

fn default_library_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "libflags2env.dylib"
    } else if cfg!(target_os = "windows") {
        "flags2env.dll"
    } else {
        "libflags2env.so"
    }
}
