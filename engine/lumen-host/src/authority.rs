use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use lumen_engine::settings::{SettingsAuthority, SettingsCapabilities, SettingsProtocolError};
use lumen_engine::{
    ApplicationCatalog, AuthAuthority, AuthErrorCode, CatalogError, HostIdentityAuthority,
    HostIdentityError,
};

use crate::HostArguments;

mod resource_capabilities;

use resource_capabilities::native_settings_capabilities;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostAuthorityPaths {
    pub settings: PathBuf,
    pub owner_account: PathBuf,
    pub devices: PathBuf,
    pub applications: PathBuf,
    pub host_identity: PathBuf,
}

impl HostAuthorityPaths {
    pub fn from_arguments(arguments: &HostArguments) -> Result<Self, HostAuthorityError> {
        let credentials = required_path(arguments, "credentials_file")?;
        let Some(storage_root) = credentials
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
        else {
            return Err(HostAuthorityError::InvalidStorageRoot(credentials));
        };
        Ok(Self {
            settings: storage_root.join("settings.json"),
            owner_account: storage_root.join("owner-account.json"),
            devices: storage_root.join("devices.json"),
            applications: required_path(arguments, "file_apps")?,
            host_identity: required_path(arguments, "file_state")?,
        })
    }

    fn storage_directories(&self) -> impl Iterator<Item = &Path> {
        [
            self.settings.parent(),
            self.owner_account.parent(),
            self.devices.parent(),
            self.applications.parent(),
            self.host_identity.parent(),
        ]
        .into_iter()
        .flatten()
    }
}

fn required_path(
    arguments: &HostArguments,
    key: &'static str,
) -> Result<PathBuf, HostAuthorityError> {
    arguments
        .get(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or(HostAuthorityError::MissingPath(key))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HostAuthorityError {
    MissingPath(&'static str),
    InvalidStorageRoot(PathBuf),
    Storage(PathBuf),
    Settings(SettingsProtocolError),
    Authentication(AuthErrorCode),
    Applications(CatalogError),
    HostIdentity(HostIdentityError),
}

impl fmt::Display for HostAuthorityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingPath(key) => write!(formatter, "authority path is missing: {key}"),
            Self::InvalidStorageRoot(path) => {
                write!(
                    formatter,
                    "authority storage root is invalid: {}",
                    path.display()
                )
            }
            Self::Storage(path) => {
                write!(
                    formatter,
                    "authority directory could not be created: {}",
                    path.display()
                )
            }
            Self::Settings(error) => write!(formatter, "settings authority failed: {error:?}"),
            Self::Authentication(error) => {
                write!(formatter, "authentication authority failed: {error:?}")
            }
            Self::Applications(error) => {
                write!(formatter, "application authority failed: {error:?}")
            }
            Self::HostIdentity(error) => write!(formatter, "host identity failed: {error:?}"),
        }
    }
}

impl std::error::Error for HostAuthorityError {}

pub struct HostAuthorities {
    paths: HostAuthorityPaths,
    settings: SettingsAuthority,
    authentication: AuthAuthority,
    applications: ApplicationCatalog,
    host_identity: HostIdentityAuthority,
}

impl HostAuthorities {
    pub fn open_native(paths: HostAuthorityPaths) -> Result<Self, HostAuthorityError> {
        Self::open_with_capabilities(paths, native_settings_capabilities())
    }

    fn open_with_capabilities(
        paths: HostAuthorityPaths,
        capabilities: SettingsCapabilities,
    ) -> Result<Self, HostAuthorityError> {
        for directory in paths.storage_directories() {
            if directory.as_os_str().is_empty() {
                continue;
            }
            fs::create_dir_all(directory)
                .map_err(|_| HostAuthorityError::Storage(directory.to_owned()))?;
        }
        let settings = SettingsAuthority::open(paths.settings.clone(), capabilities)
            .map_err(HostAuthorityError::Settings)?;
        let authentication =
            AuthAuthority::open(paths.owner_account.clone(), paths.devices.clone())
                .map_err(HostAuthorityError::Authentication)?;
        let applications = ApplicationCatalog::open(paths.applications.clone())
            .map_err(HostAuthorityError::Applications)?;
        let host_identity = HostIdentityAuthority::open(paths.host_identity.clone())
            .map_err(HostAuthorityError::HostIdentity)?;
        Ok(Self {
            paths,
            settings,
            authentication,
            applications,
            host_identity,
        })
    }

    pub fn reconcile_native_settings(
        &mut self,
        arguments: &HostArguments,
    ) -> Result<(), HostAuthorityError> {
        let runtime =
            crate::local_settings::from_arguments(arguments, self.settings.snapshot().effective)
                .map_err(|message| {
                    HostAuthorityError::Settings(SettingsProtocolError {
                        code: lumen_engine::settings::SettingsErrorCode::InvalidValue,
                        message,
                        field: None,
                        current_revision: Some(self.settings.snapshot().revision),
                    })
                })?;
        self.settings
            .apply_local_update(runtime)
            .and_then(|_| self.settings.mark_worker_restarted())
            .map(|_| ())
            .map_err(HostAuthorityError::Settings)
    }

    pub fn paths(&self) -> &HostAuthorityPaths {
        &self.paths
    }

    pub fn settings(&self) -> &SettingsAuthority {
        &self.settings
    }

    pub fn settings_mut(&mut self) -> &mut SettingsAuthority {
        &mut self.settings
    }

    pub fn authentication(&self) -> &AuthAuthority {
        &self.authentication
    }

    pub fn authentication_mut(&mut self) -> &mut AuthAuthority {
        &mut self.authentication
    }

    pub fn set_device_enrollment_enabled(&mut self, enabled: bool) {
        self.authentication.set_device_enrollment_enabled(enabled);
    }

    pub fn applications(&self) -> &ApplicationCatalog {
        &self.applications
    }

    pub fn host_identity(&self) -> &HostIdentityAuthority {
        &self.host_identity
    }

    pub fn reload_applications(&mut self) -> Result<(), HostAuthorityError> {
        self.applications = ApplicationCatalog::open(self.paths.applications.clone())
            .map_err(HostAuthorityError::Applications)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_all_native_authorities_under_one_rust_composition() {
        let root = tempfile::tempdir().unwrap();
        let paths = HostAuthorityPaths {
            settings: root.path().join("settings.json"),
            owner_account: root.path().join("owner-account.json"),
            devices: root.path().join("devices.json"),
            applications: root.path().join("apps.json"),
            host_identity: root.path().join("lumen-state.json"),
        };
        let mut authorities = HostAuthorities::open_native(paths.clone()).unwrap();
        assert_eq!(authorities.paths(), &paths);
        assert_eq!(authorities.settings().snapshot().schema_version, 1);
        assert!(paths.applications.exists());
        assert!(paths.host_identity.exists());
        assert!(
            String::from_utf8(authorities.applications().json().unwrap())
                .unwrap()
                .contains("\"apps\"")
        );

        fs::write(&paths.applications, r#"{"apps":[]}"#).unwrap();
        authorities.reload_applications().unwrap();
    }

    #[test]
    fn derives_current_authority_files_from_the_native_launch_contract() {
        let arguments = crate::config::tests::valid_arguments_for_runtime_tests();
        let paths = HostAuthorityPaths::from_arguments(&arguments).unwrap();
        assert_eq!(paths.settings, PathBuf::from("/tmp/settings.json"));
        assert_eq!(
            paths.owner_account,
            PathBuf::from("/tmp/owner-account.json")
        );
        assert_eq!(paths.devices, PathBuf::from("/tmp/devices.json"));
        assert_eq!(paths.applications, PathBuf::from("/tmp/apps.json"));
        assert_eq!(paths.host_identity, PathBuf::from("/tmp/state.json"));
    }
}
