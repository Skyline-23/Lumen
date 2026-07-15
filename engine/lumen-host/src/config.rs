use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fmt;

const REQUIRED_ARGUMENTS: &[&str] = &[
    "host_name",
    "enable_discovery",
    "device_enrollment_enabled",
    "notify_pre_releases",
    "workspace_policy",
    "global_prep_cmd",
    "global_state_cmd",
    "server_cmd",
    "fallback_mode",
    "stream_audio",
    "keyboard",
    "mouse",
    "controller",
    "back_button_timeout",
    "key_rightalt_to_key_win",
    "high_resolution_scrolling",
    "native_pen_touch",
    "forward_rumble",
    "address_family",
    "port",
    "upnp",
    "origin_admin_allowed",
    "lan_encryption_mode",
    "wan_encryption_mode",
    "ping_timeout",
    "fec_percentage",
    "min_log_level",
    "file_apps",
    "credentials_file",
    "log_path",
    "pkey",
    "cert",
    "file_state",
];

const OPTIONAL_ARGUMENTS: &[&str] = &["adapter_name", "output_name", "audio_sink"];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostArguments {
    values: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HostArgumentsError {
    NonUnicode,
    Malformed(String),
    Unknown(String),
    Duplicate(String),
    Missing(String),
    InvalidValue { key: String, value: String },
}

impl fmt::Display for HostArgumentsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NonUnicode => formatter.write_str("an argument is not valid Unicode"),
            Self::Malformed(value) => write!(formatter, "argument must be key=value: {value}"),
            Self::Unknown(key) => write!(formatter, "unknown argument: {key}"),
            Self::Duplicate(key) => write!(formatter, "duplicate argument: {key}"),
            Self::Missing(key) => write!(formatter, "required argument is missing: {key}"),
            Self::InvalidValue { key, value } => {
                write!(formatter, "invalid value for {key}: {value}")
            }
        }
    }
}

impl std::error::Error for HostArgumentsError {}

impl HostArguments {
    pub fn parse_process<I, S>(arguments: I) -> Result<Self, HostArgumentsError>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let arguments = arguments.into_iter().map(Into::into).collect::<Vec<_>>();
        #[cfg(windows)]
        if arguments.is_empty() {
            return Self::windows_defaults();
        }
        Self::parse(arguments)
    }

    pub fn parse<I, S>(arguments: I) -> Result<Self, HostArgumentsError>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let mut values = BTreeMap::new();
        for argument in arguments {
            let argument = argument.into();
            let argument = argument.to_str().ok_or(HostArgumentsError::NonUnicode)?;
            let Some((key, value)) = argument.split_once('=') else {
                return Err(HostArgumentsError::Malformed(argument.to_owned()));
            };
            if key.is_empty() {
                return Err(HostArgumentsError::Malformed(argument.to_owned()));
            }
            if !REQUIRED_ARGUMENTS.contains(&key) && !OPTIONAL_ARGUMENTS.contains(&key) {
                return Err(HostArgumentsError::Unknown(key.to_owned()));
            }
            if values.insert(key.to_owned(), value.to_owned()).is_some() {
                return Err(HostArgumentsError::Duplicate(key.to_owned()));
            }
        }
        for key in REQUIRED_ARGUMENTS {
            if !values.contains_key(*key) {
                return Err(HostArgumentsError::Missing((*key).to_owned()));
            }
        }
        let parsed = Self { values };
        parsed.validate()?;
        Ok(parsed)
    }

    pub fn len(&self) -> usize {
        self.values.len()
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }

    fn validate(&self) -> Result<(), HostArgumentsError> {
        self.require_one_of(
            "workspace_policy",
            &[
                "coexist",
                "promote-virtual-main",
                "focused-workspace",
                "isolated-workspace",
            ],
        )?;
        self.require_one_of("address_family", &["ipv4", "both"])?;
        self.require_one_of("origin_admin_allowed", &["pc", "lan", "wan"])?;
        self.require_one_of(
            "min_log_level",
            &[
                "verbose", "debug", "info", "warning", "error", "fatal", "none",
            ],
        )?;
        self.require_range("port", 1_029, 65_515)?;
        self.require_range("lan_encryption_mode", 0, 2)?;
        self.require_range("wan_encryption_mode", 0, 2)?;
        self.require_range("ping_timeout", 1_000, 120_000)?;
        self.require_range("fec_percentage", 1, 255)?;
        for key in [
            "enable_discovery",
            "device_enrollment_enabled",
            "notify_pre_releases",
            "stream_audio",
            "keyboard",
            "mouse",
            "controller",
            "key_rightalt_to_key_win",
            "high_resolution_scrolling",
            "native_pen_touch",
            "forward_rumble",
            "upnp",
        ] {
            self.require_one_of(key, &["true", "false"])?;
        }
        for key in [
            "host_name",
            "fallback_mode",
            "file_apps",
            "credentials_file",
            "log_path",
            "pkey",
            "cert",
            "file_state",
        ] {
            if self.get(key).is_none_or(str::is_empty) {
                return Err(self.invalid(key));
            }
        }
        Ok(())
    }

    fn require_one_of(&self, key: &str, allowed: &[&str]) -> Result<(), HostArgumentsError> {
        if self.get(key).is_some_and(|value| allowed.contains(&value)) {
            Ok(())
        } else {
            Err(self.invalid(key))
        }
    }

    fn require_range(
        &self,
        key: &str,
        minimum: i64,
        maximum: i64,
    ) -> Result<(), HostArgumentsError> {
        if self
            .get(key)
            .and_then(|value| value.parse::<i64>().ok())
            .is_some_and(|value| (minimum..=maximum).contains(&value))
        {
            Ok(())
        } else {
            Err(self.invalid(key))
        }
    }

    fn invalid(&self, key: &str) -> HostArgumentsError {
        HostArgumentsError::InvalidValue {
            key: key.to_owned(),
            value: self.get(key).unwrap_or_default().to_owned(),
        }
    }

    #[cfg(windows)]
    fn windows_defaults() -> Result<Self, HostArgumentsError> {
        let executable = std::env::current_exe().map_err(|_| HostArgumentsError::InvalidValue {
            key: "runtime_root".to_owned(),
            value: String::new(),
        })?;
        let root = executable
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .ok_or_else(|| HostArgumentsError::InvalidValue {
                key: "runtime_root".to_owned(),
                value: executable.to_string_lossy().into_owned(),
            })?
            .join("config");
        let credentials = root.join("credentials");
        let path = |value: std::path::PathBuf| value.to_string_lossy().into_owned();
        let host_name = std::env::var("COMPUTERNAME")
            .ok()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "Lumen".to_owned());
        Self::parse([
            format!("host_name={host_name}"),
            "enable_discovery=true".to_owned(),
            "device_enrollment_enabled=true".to_owned(),
            "notify_pre_releases=false".to_owned(),
            "workspace_policy=coexist".to_owned(),
            "global_prep_cmd=[]".to_owned(),
            "global_state_cmd=[]".to_owned(),
            "server_cmd=[]".to_owned(),
            "fallback_mode=1920x1080x60".to_owned(),
            "stream_audio=true".to_owned(),
            "keyboard=true".to_owned(),
            "mouse=true".to_owned(),
            "controller=true".to_owned(),
            "back_button_timeout=-1".to_owned(),
            "key_rightalt_to_key_win=true".to_owned(),
            "high_resolution_scrolling=true".to_owned(),
            "native_pen_touch=true".to_owned(),
            "forward_rumble=true".to_owned(),
            "address_family=ipv4".to_owned(),
            "port=47989".to_owned(),
            "upnp=false".to_owned(),
            "origin_admin_allowed=lan".to_owned(),
            "lan_encryption_mode=0".to_owned(),
            "wan_encryption_mode=1".to_owned(),
            "ping_timeout=10000".to_owned(),
            "fec_percentage=20".to_owned(),
            "min_log_level=info".to_owned(),
            format!("file_apps={}", path(root.join("apps.json"))),
            format!("credentials_file={}", path(root.join("lumen_state.json"))),
            format!("log_path={}", path(root.join("lumen.log"))),
            format!("pkey={}", path(credentials.join("cakey.pem"))),
            format!("cert={}", path(credentials.join("cacert.pem"))),
            format!("file_state={}", path(root.join("lumen_state.json"))),
        ])
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn valid_arguments() -> Vec<String> {
        REQUIRED_ARGUMENTS
            .iter()
            .map(|key| {
                let value = match *key {
                    "address_family" => "both",
                    "port" => "47989",
                    "origin_admin_allowed" => "lan",
                    "lan_encryption_mode" | "wan_encryption_mode" => "1",
                    "ping_timeout" => "10000",
                    "fec_percentage" => "20",
                    "min_log_level" => "info",
                    "enable_discovery"
                    | "device_enrollment_enabled"
                    | "notify_pre_releases"
                    | "stream_audio"
                    | "keyboard"
                    | "mouse"
                    | "controller"
                    | "key_rightalt_to_key_win"
                    | "high_resolution_scrolling"
                    | "native_pen_touch"
                    | "forward_rumble"
                    | "upnp" => "true",
                    "workspace_policy" => "coexist",
                    "global_prep_cmd" | "global_state_cmd" | "server_cmd" => "[]",
                    "back_button_timeout" => "-1",
                    "host_name" => "Lumen",
                    "fallback_mode" => "1920x1080x60",
                    "file_apps" => "/tmp/apps.json",
                    "credentials_file" => "/tmp/credentials.json",
                    "log_path" => "/tmp/lumen.log",
                    "pkey" => "/tmp/key.pem",
                    "cert" => "/tmp/cert.pem",
                    "file_state" => "/tmp/state.json",
                    _ => "value",
                };
                format!("{key}={value}")
            })
            .collect()
    }

    pub(crate) fn valid_arguments_for_runtime_tests() -> HostArguments {
        HostArguments::parse(valid_arguments()).unwrap()
    }

    #[test]
    fn accepts_the_current_native_runtime_contract() {
        let parsed = HostArguments::parse(valid_arguments()).unwrap();
        assert_eq!(parsed.get("port"), Some("47989"));
        assert_eq!(parsed.len(), REQUIRED_ARGUMENTS.len());
    }

    #[test]
    fn rejects_unknown_duplicate_missing_and_invalid_values() {
        let mut unknown = valid_arguments();
        unknown.push("legacy_engine=true".to_owned());
        assert_eq!(
            HostArguments::parse(unknown),
            Err(HostArgumentsError::Unknown("legacy_engine".to_owned()))
        );

        let mut duplicate = valid_arguments();
        duplicate.push("port=48000".to_owned());
        assert_eq!(
            HostArguments::parse(duplicate),
            Err(HostArgumentsError::Duplicate("port".to_owned()))
        );

        let mut missing = valid_arguments();
        missing.retain(|argument| !argument.starts_with("cert="));
        assert_eq!(
            HostArguments::parse(missing),
            Err(HostArgumentsError::Missing("cert".to_owned()))
        );

        let mut invalid = valid_arguments();
        let port = invalid
            .iter_mut()
            .find(|argument| argument.starts_with("port="))
            .unwrap();
        *port = "port=80".to_owned();
        assert!(matches!(
            HostArguments::parse(invalid),
            Err(HostArgumentsError::InvalidValue { key, .. }) if key == "port"
        ));
    }

    #[test]
    fn rejects_non_unicode_process_arguments() {
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStringExt;
            let value = OsString::from_vec(vec![0xff, b'=']);
            assert_eq!(
                HostArguments::parse([value]),
                Err(HostArgumentsError::NonUnicode)
            );
        }
    }

    #[test]
    fn os_str_contract_is_available_to_process_boundaries() {
        let value: &std::ffi::OsStr = std::ffi::OsStr::new("port=47989");
        assert_eq!(value.to_string_lossy(), "port=47989");
    }
}
