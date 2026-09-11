use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::{
    coercion_input_json, decode_coercion_report, CoercionError, ResolvedCommands, StructuredParse,
};

unsafe extern "C" {
    fn f2e_coerce_json(values_json: *const c_char) -> *mut c_char;
    fn f2e_coerce_json_from_file(
        config_path: *const c_char,
        values_json: *const c_char,
    ) -> *mut c_char;
    fn f2e_parse_json_argv(argv_json: *const c_char) -> *mut c_char;
    fn f2e_parse_json_argv_from_file(
        config_path: *const c_char,
        argv_json: *const c_char,
    ) -> *mut c_char;
    fn f2e_parse_process() -> *mut c_char;
    fn f2e_parse_process_from_file(config_path: *const c_char) -> *mut c_char;
    fn f2e_parse_structured_json_argv(argv_json: *const c_char) -> *mut c_char;
    fn f2e_parse_structured_json_argv_from_file(
        config_path: *const c_char,
        argv_json: *const c_char,
    ) -> *mut c_char;
    fn f2e_resolve_commands_json_argv(argv_json: *const c_char) -> *mut c_char;
    fn f2e_resolve_commands_json_argv_from_file(
        config_path: *const c_char,
        argv_json: *const c_char,
    ) -> *mut c_char;
    fn f2e_is_help_requested_json_argv(argv_json: *const c_char) -> i32;
    fn f2e_help_table_for_json_argv(
        command_name: *const c_char,
        argv_json: *const c_char,
        terminal_columns: i32,
    ) -> *mut c_char;
    fn f2e_help_table_for_json_argv_from_file(
        config_path: *const c_char,
        command_name: *const c_char,
        argv_json: *const c_char,
        terminal_columns: i32,
    ) -> *mut c_char;
    fn f2e_completion_script(shell: *const c_char, command_name: *const c_char) -> *mut c_char;
    fn f2e_completion_script_from_file(
        config_path: *const c_char,
        shell: *const c_char,
        command_name: *const c_char,
    ) -> *mut c_char;
    fn f2e_audit_config_status() -> i32;
    fn f2e_audit_config_status_from_file(config_path: *const c_char) -> i32;
    fn f2e_doctor_from_file(config_path: *const c_char) -> *mut c_char;
    fn f2e_doctor_status_from_file(config_path: *const c_char) -> i32;
    fn f2e_free(value: *mut c_char);
}

/// A statically linked flags2env parser.
///
/// This backend compiles the vendored C parser through the crate's build script,
/// so release binaries and minimal containers do not need an external
/// `libflags2env` shared library. Use [`crate::Flags2Env`] only when runtime
/// loading or an explicitly selected shared library is required.
#[derive(Debug, Default, Clone, Copy)]
pub struct BundledFlags2Env;

impl BundledFlags2Env {
    pub const fn new() -> Self {
        Self
    }

    pub fn parse(
        &self,
        argv: &[String],
        config_path: Option<&str>,
    ) -> Result<HashMap<String, String>, Box<dyn std::error::Error>> {
        let raw = call_json_argv(
            argv,
            config_path,
            f2e_parse_json_argv,
            f2e_parse_json_argv_from_file,
        )?
        .unwrap_or_else(|| "{}".to_string());
        Ok(serde_json::from_str(&raw)?)
    }

    pub fn parse_process(
        &self,
        config_path: Option<&str>,
    ) -> Result<HashMap<String, String>, Box<dyn std::error::Error>> {
        let result = if let Some(config_path) = config_path {
            let config_path = CString::new(config_path)?;
            // SAFETY: the CString lives through the call and the C API returns
            // either NULL or a heap string released by f2e_free.
            unsafe { f2e_parse_process_from_file(config_path.as_ptr()) }
        } else {
            // SAFETY: the C API takes no arguments and returns an owned string.
            unsafe { f2e_parse_process() }
        };
        let raw = take_owned_string(result).unwrap_or_else(|| "{}".to_string());
        Ok(serde_json::from_str(&raw)?)
    }

    /// Returns true only when argv contains the exact `--help` token.
    ///
    /// This delegates to the same native parser authority used by the bundled
    /// CLI instead of making each Rust consumer implement its own help-token
    /// scanner.
    pub fn is_help_requested(
        &self,
        argv: &[String],
    ) -> Result<bool, Box<dyn std::error::Error>> {
        let argv_json = CString::new(serde_json::to_string(argv)?)?;
        // SAFETY: argv_json is a valid NUL-terminated JSON array for the
        // duration of the call; the C API does not retain the pointer.
        Ok(unsafe { f2e_is_help_requested_json_argv(argv_json.as_ptr()) != 0 })
    }

    /// Renders the terminal-width-aware help table for the command scope
    /// selected by `argv`.
    ///
    /// Passing `terminal_columns <= 0` preserves the native auto-detection
    /// behavior. The returned string is owned Rust data; native allocation is
    /// released before this method returns.
    pub fn help_table_for_argv(
        &self,
        command_name: &str,
        argv: &[String],
        terminal_columns: i32,
        config_path: Option<&str>,
    ) -> Result<String, Box<dyn std::error::Error>> {
        let command_name = CString::new(command_name)?;
        let argv_json = CString::new(serde_json::to_string(argv)?)?;
        let result = if let Some(config_path) = config_path {
            let config_path = CString::new(config_path)?;
            // SAFETY: all CStrings live through the call and the returned heap
            // string is released by take_owned_string.
            unsafe {
                f2e_help_table_for_json_argv_from_file(
                    config_path.as_ptr(),
                    command_name.as_ptr(),
                    argv_json.as_ptr(),
                    terminal_columns,
                )
            }
        } else {
            // SAFETY: command_name and argv_json remain alive through the call;
            // the returned heap string is released by take_owned_string.
            unsafe {
                f2e_help_table_for_json_argv(
                    command_name.as_ptr(),
                    argv_json.as_ptr(),
                    terminal_columns,
                )
            }
        };
        take_owned_string(result)
            .ok_or_else(|| "flags2env could not render help; check the config path".into())
    }

    /// Generates a static shell-completion script from the same
    /// `.cli-flags.toml` authority used for parsing.
    pub fn completion_script(
        &self,
        shell: &str,
        command_name: &str,
        config_path: Option<&str>,
    ) -> Result<String, Box<dyn std::error::Error>> {
        let shell = CString::new(shell)?;
        let command_name = CString::new(command_name)?;
        let result = if let Some(config_path) = config_path {
            let config_path = CString::new(config_path)?;
            // SAFETY: all CStrings live through the call and the returned heap
            // string is released by take_owned_string.
            unsafe {
                f2e_completion_script_from_file(
                    config_path.as_ptr(),
                    shell.as_ptr(),
                    command_name.as_ptr(),
                )
            }
        } else {
            // SAFETY: shell and command_name remain alive through the call; the
            // returned heap string is released by take_owned_string.
            unsafe { f2e_completion_script(shell.as_ptr(), command_name.as_ptr()) }
        };
        take_owned_string(result)
            .ok_or_else(|| "flags2env could not generate completion script".into())
    }

    /// Coerce declared environment values according to `.cli-flags.toml` and
    /// deserialize the result into `T`.
    ///
    /// This is the self-contained equivalent of
    /// [`crate::Flags2Env::coerce`]. It accepts parsed flags, a merged
    /// environment/flags map, or any serializable object and reports all schema
    /// conversion failures through [`CoercionError::Validation`].
    pub fn coerce<T, V>(&self, values: &V, config_path: Option<&str>) -> Result<T, CoercionError>
    where
        T: DeserializeOwned,
        V: Serialize + ?Sized,
    {
        let values_json = coercion_input_json(values)?;
        let result = if let Some(config_path) = config_path {
            let config_path = CString::new(config_path)?;
            // SAFETY: both CStrings remain alive through the call and the C API
            // returns either NULL or a heap string released by f2e_free.
            unsafe { f2e_coerce_json_from_file(config_path.as_ptr(), values_json.as_ptr()) }
        } else {
            // SAFETY: values_json is a valid NUL-terminated JSON object.
            unsafe { f2e_coerce_json(values_json.as_ptr()) }
        };
        let raw = take_owned_string(result).ok_or(CoercionError::NativeUnavailable)?;
        decode_coercion_report(&raw)
    }

    pub fn parse_structured(
        &self,
        argv: &[String],
        config_path: Option<&str>,
    ) -> Result<StructuredParse, Box<dyn std::error::Error>> {
        let raw = call_json_argv(
            argv,
            config_path,
            f2e_parse_structured_json_argv,
            f2e_parse_structured_json_argv_from_file,
        )?
        .ok_or("flags2env could not parse argv; check the config path")?;
        let report: serde_json::Value = serde_json::from_str(&raw)?;
        Ok(StructuredParse {
            flags: json_string_map(report.get("flags")),
            provided_flags: required_json_string_map(
                report.get("providedFlags"),
                "bundled flags2env parser did not return argv-only overrides",
            )?,
            dotenv: json_string_map(report.get("dotenv")),
            dotenv_overrides: json_string_map(report.get("dotenvOverrides")),
            source_order: json_string_vec_map(report.get("sourceOrder")),
            command: report
                .get("command")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string(),
            subcommands: json_string_vec(report.get("subcommands")),
            extras: json_string_vec(report.get("extras")),
            unknown_options: json_string_vec(report.get("unknownOptions")),
            errors: json_string_vec(report.get("errors")),
        })
    }

    pub fn resolve_commands(
        &self,
        argv: &[String],
        config_path: Option<&str>,
    ) -> Result<ResolvedCommands, Box<dyn std::error::Error>> {
        let raw = call_json_argv(
            argv,
            config_path,
            f2e_resolve_commands_json_argv,
            f2e_resolve_commands_json_argv_from_file,
        )?
        .ok_or("flags2env could not resolve commands; check the config path")?;
        let report: serde_json::Value = serde_json::from_str(&raw)?;
        Ok(ResolvedCommands {
            path: json_string_vec(report.get("path")),
            label: report
                .get("label")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string(),
        })
    }

    pub fn audit_config(
        &self,
        config_path: Option<&str>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let status = if let Some(config_path) = config_path {
            let config_path = CString::new(config_path)?;
            // SAFETY: the CString is valid for the duration of the call.
            unsafe { f2e_audit_config_status_from_file(config_path.as_ptr()) }
        } else {
            // SAFETY: the C API takes no arguments.
            unsafe { f2e_audit_config_status() }
        };
        if status == 0 {
            Ok(())
        } else {
            Err(format!("flags2env config audit failed with status {status}").into())
        }
    }

    /// Diagnoses the `.env` files `config_path` reads: every file in
    /// `[env] files`, or `./.env` when that key is absent.
    ///
    /// Returns the JSON report as a string — the same
    /// `{"ok", "errorCount", "warningCount", "errors", "warnings"}` shape
    /// [`Self::audit_config`] produces — so a caller can print it, or parse it
    /// to render findings its own way. Values from the `.env` are never
    /// included, only key names and positions.
    pub fn doctor(&self, config_path: &str) -> Result<String, Box<dyn std::error::Error>> {
        let config_path = CString::new(config_path)?;
        // SAFETY: the CString is valid for the duration of the call; the
        // returned pointer is owned by the caller and released by
        // `take_owned_string`.
        let result = unsafe { f2e_doctor_from_file(config_path.as_ptr()) };
        take_owned_string(result)
            .ok_or_else(|| "flags2env could not run doctor; check the config path".into())
    }

    /// `Ok(())` when `doctor` found no error-level problem. Warnings —
    /// ambiguity, permissions — do not fail, matching the CLI's exit code, so
    /// this is usable as a build-script or test gate.
    pub fn doctor_status(&self, config_path: &str) -> Result<(), Box<dyn std::error::Error>> {
        let config_path = CString::new(config_path)?;
        // SAFETY: the CString is valid for the duration of the call.
        let status = unsafe { f2e_doctor_status_from_file(config_path.as_ptr()) };
        if status == 0 {
            Ok(())
        } else {
            Err(format!("flags2env doctor reported {status} error-level finding(s)").into())
        }
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

fn call_json_argv(
    argv: &[String],
    config_path: Option<&str>,
    call: unsafe extern "C" fn(*const c_char) -> *mut c_char,
    call_from_file: unsafe extern "C" fn(*const c_char, *const c_char) -> *mut c_char,
) -> Result<Option<String>, Box<dyn std::error::Error>> {
    let argv_json = CString::new(serde_json::to_string(argv)?)?;
    let result = if let Some(config_path) = config_path {
        let config_path = CString::new(config_path)?;
        // SAFETY: both CStrings remain alive through the call.
        unsafe { call_from_file(config_path.as_ptr(), argv_json.as_ptr()) }
    } else {
        // SAFETY: argv_json is a valid NUL-terminated JSON string.
        unsafe { call(argv_json.as_ptr()) }
    };
    Ok(take_owned_string(result))
}

fn take_owned_string(value: *mut c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    // SAFETY: flags2env returns a NUL-terminated heap string and requires
    // f2e_free to release it exactly once.
    let text = unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned();
    unsafe { f2e_free(value) };
    Some(text)
}

fn json_string_vec(value: Option<&serde_json::Value>) -> Vec<String> {
    value
        .and_then(serde_json::Value::as_array)
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
        .and_then(serde_json::Value::as_object)
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

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn config() -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("temporary directory");
        fs::write(
            dir.path().join(".cli-flags.toml"),
            r#"
[parse]
allow_unknown = false
unknown_options_env = "UNKNOWN_OPTIONS"
errors_env = "PARSE_ERRORS"

[flags.port]
env = "PORT"
aliases = ["port"]
type = "integer"
default = 3000
help = "TCP port for the app listener."

[flags.debug]
env = "DEBUG"
aliases = ["debug"]
type = "bool"
default = false
help = "Enable debug logging."

[flags.ratio]
env = "RATIO"
aliases = ["ratio"]
type = "double"
default = 1.5

[flags.items]
env = "ITEMS"
aliases = ["items"]
type = "array"

[flags.labels]
env = "LABELS"
aliases = ["labels"]
type = "map"

[commands.serve]
env = "COMMAND_SERVE"
help = "Run the server."

[commands.serve.flags.bind]
env = "BIND_ADDR"
aliases = ["bind"]
type = "string"
default = "127.0.0.1:8080"
help = "Server bind address."
"#,
        )
        .expect("write config");
        dir
    }

    #[allow(non_snake_case)]
    #[derive(Debug, serde::Deserialize, PartialEq)]
    struct GeneratedConfig {
        PORT: i64,
        DEBUG: bool,
        RATIO: f64,
        ITEMS: Option<Vec<serde_json::Value>>,
        LABELS: Option<HashMap<String, serde_json::Value>>,
        BIND_ADDR: Option<String>,
        COMMAND_SERVE: Option<bool>,
    }

    #[test]
    fn bundled_parser_applies_flags_and_scoped_defaults() {
        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        let argv = vec![
            "app".to_string(),
            "serve".to_string(),
            "--port=4100".to_string(),
        ];
        let parsed = BundledFlags2Env::new()
            .parse(&argv, path.to_str())
            .expect("parse flags");
        assert_eq!(parsed.get("PORT").map(String::as_str), Some("4100"));
        assert_eq!(
            parsed.get("BIND_ADDR").map(String::as_str),
            Some("127.0.0.1:8080")
        );
        assert_eq!(
            parsed.get("COMMAND_SERVE").map(String::as_str),
            Some("true")
        );
    }

    #[test]
    fn bundled_ui_helpers_use_native_command_scope() {
        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        let parser = BundledFlags2Env::new();
        let help_argv = vec![
            "app".to_string(),
            "serve".to_string(),
            "--help".to_string(),
        ];
        let non_help_argv = vec!["app".to_string(), "--helpful".to_string()];

        assert!(
            parser
                .is_help_requested(&help_argv)
                .expect("detect exact help token")
        );
        assert!(
            !parser
                .is_help_requested(&non_help_argv)
                .expect("reject help prefix")
        );

        let help = parser
            .help_table_for_argv("app", &help_argv, 100, path.to_str())
            .expect("render scoped help");
        assert!(help.contains("--bind"), "scoped help omitted command flag: {help}");
        assert!(help.contains("--port"), "scoped help omitted global flag: {help}");

        let completion = parser
            .completion_script("bash", "app", path.to_str())
            .expect("generate bash completion");
        assert!(completion.contains("serve"), "completion omitted command");
        assert!(completion.contains("--port"), "completion omitted global flag");
    }

    #[test]
    fn bundled_coerce_deserializes_generated_shape() {
        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        let argv = vec![
            "app".to_string(),
            "serve".to_string(),
            "--port=4100".to_string(),
            "--debug".to_string(),
            "--items=[1,\"two\"]".to_string(),
            "--labels={\"tier\":2}".to_string(),
        ];
        let parsed = BundledFlags2Env::new()
            .parse(&argv, path.to_str())
            .expect("parse flags");
        let coerced: GeneratedConfig = BundledFlags2Env::new()
            .coerce(&parsed, path.to_str())
            .expect("coerce parsed flags");

        assert_eq!(coerced.PORT, 4100);
        assert!(coerced.DEBUG);
        assert_eq!(coerced.RATIO, 1.5);
        assert_eq!(
            coerced.ITEMS,
            Some(vec![serde_json::json!(1), serde_json::json!("two")])
        );
        assert_eq!(
            coerced
                .LABELS
                .as_ref()
                .and_then(|labels| labels.get("tier")),
            Some(&serde_json::json!(2))
        );
        assert_eq!(coerced.BIND_ADDR.as_deref(), Some("127.0.0.1:8080"));
        assert_eq!(coerced.COMMAND_SERVE, Some(true));
    }

    #[test]
    fn bundled_coerce_accepts_typed_values_and_applies_defaults() {
        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        let values = serde_json::json!({
            "DEBUG": true,
            "ITEMS": [3, 4],
            "LABELS": {"tier": 2},
            "UNDECLARED": "ignored"
        });
        let coerced: GeneratedConfig = BundledFlags2Env::new()
            .coerce(&values, path.to_str())
            .expect("coerce typed values");

        assert_eq!(coerced.PORT, 3000);
        assert!(coerced.DEBUG);
        assert_eq!(coerced.RATIO, 1.5);
        assert_eq!(
            coerced.ITEMS,
            Some(vec![serde_json::json!(3), serde_json::json!(4)])
        );
        assert_eq!(coerced.BIND_ADDR, None);
        assert_eq!(coerced.COMMAND_SERVE, None);
    }

    #[test]
    fn bundled_provided_flags_preserve_environment_precedence() {
        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        let parser = BundledFlags2Env::new();

        let defaults_only = parser
            .parse_structured(&["app".to_string()], path.to_str())
            .expect("parse defaults");
        assert!(!defaults_only.provided_flags.contains_key("PORT"));
        let mut environment = HashMap::from([("PORT".to_string(), "9191".to_string())]);
        environment.extend(defaults_only.provided_flags);
        let from_environment: GeneratedConfig = parser
            .coerce(&environment, path.to_str())
            .expect("coerce environment");
        assert_eq!(from_environment.PORT, 9191);

        let explicit = parser
            .parse_structured(
                &["app".to_string(), "--port=4100".to_string()],
                path.to_str(),
            )
            .expect("parse override");
        environment.extend(explicit.provided_flags);
        let from_cli: GeneratedConfig = parser
            .coerce(&environment, path.to_str())
            .expect("coerce CLI override");
        assert_eq!(from_cli.PORT, 4100);
    }

    #[test]
    fn bundled_coerce_returns_all_schema_validation_errors() {
        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        let values = serde_json::json!({
            "PORT": "not-an-integer",
            "DEBUG": "maybe",
            "ITEMS": "{}",
            "COMMAND_SERVE": "yes"
        });
        let error = BundledFlags2Env::new()
            .coerce::<GeneratedConfig, _>(&values, path.to_str())
            .expect_err("invalid values must fail");
        let messages = error
            .validation_errors()
            .expect("schema validation error messages");

        assert_eq!(messages.len(), 4);
        for key in ["PORT", "DEBUG", "ITEMS", "COMMAND_SERVE"] {
            assert!(
                messages.iter().any(|message| message.contains(key)),
                "missing validation message for {key}: {messages:?}"
            );
        }
    }

    #[test]
    fn bundled_coerce_reports_requested_type_mismatch() {
        #[allow(dead_code, non_snake_case)]
        #[derive(Debug, serde::Deserialize)]
        struct WrongConfig {
            PORT: bool,
        }

        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        let error = BundledFlags2Env::new()
            .coerce::<WrongConfig, _>(&serde_json::json!({}), path.to_str())
            .expect_err("wrong Rust type must fail");

        assert!(matches!(error, CoercionError::Deserialize(_)));
    }

    #[test]
    fn bundled_parser_reports_unknown_options_structurally() {
        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        let argv = vec!["app".to_string(), "--not-declared".to_string()];
        let parsed = BundledFlags2Env::new()
            .parse_structured(&argv, path.to_str())
            .expect("structured parse");
        assert_eq!(parsed.unknown_options, ["--not-declared"]);
    }

    #[test]
    fn bundled_parser_audits_explicit_config() {
        let dir = config();
        let path = dir.path().join(".cli-flags.toml");
        BundledFlags2Env::new()
            .audit_config(path.to_str())
            .expect("valid config");
    }
}
