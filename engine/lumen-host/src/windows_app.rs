use std::path::PathBuf;

use lumen_engine::settings::{
    HostSettings, SettingsAuthority, SettingsCapabilities, SettingsHostPlatform,
};
use lumen_engine::{
    ApplicationCatalog, ApplicationDescriptor, LumenOwnerState, OwnerAccountError,
    OwnerAccountStore,
};

use crate::network_ports::HostPorts;
use crate::{HostArguments, HostAuthorityPaths};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WindowsNavigation {
    Overview,
    Applications,
    Security,
    General,
    Streaming,
    Audio,
    Input,
    Network,
    Advanced,
    Diagnostics,
    About,
}

impl WindowsNavigation {
    pub(crate) fn from_index(index: i32) -> Self {
        match index {
            1 => Self::Applications,
            2 => Self::Security,
            3 => Self::General,
            4 => Self::Streaming,
            5 => Self::Audio,
            6 => Self::Input,
            7 => Self::Network,
            8 => Self::Advanced,
            9 => Self::Diagnostics,
            10 => Self::About,
            _ => Self::Overview,
        }
    }

    pub(crate) fn index(self) -> i32 {
        match self {
            Self::Overview => 0,
            Self::Applications => 1,
            Self::Security => 2,
            Self::General => 3,
            Self::Streaming => 4,
            Self::Audio => 5,
            Self::Input => 6,
            Self::Network => 7,
            Self::Advanced => 8,
            Self::Diagnostics => 9,
            Self::About => 10,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum WindowsOwnerAccessState {
    SetupRequired,
    LoginRequired(String),
    Authenticated(String),
    Corrupt,
    Unavailable,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct WindowsAppSnapshot {
    pub(crate) owner_access: WindowsOwnerAccessState,
    pub(crate) navigation: WindowsNavigation,
    pub(crate) host_name: String,
    pub(crate) control_port: u16,
    pub(crate) applications: Vec<ApplicationDescriptor>,
    pub(crate) settings: HostSettings,
}

pub(crate) struct WindowsAppModel {
    owner_store: OwnerAccountStore,
    settings_path: PathBuf,
    applications_path: PathBuf,
    owner_access: WindowsOwnerAccessState,
    navigation: WindowsNavigation,
    host_name: String,
    control_port: u16,
}

impl WindowsAppModel {
    pub(crate) fn from_arguments(arguments: &HostArguments) -> Result<Self, String> {
        let paths =
            HostAuthorityPaths::from_arguments(arguments).map_err(|error| error.to_string())?;
        let owner_store = OwnerAccountStore::open(paths.owner_account.clone())
            .map_err(|error| format!("owner account store failed: {error:?}"))?;
        let host_name = arguments
            .get("host_name")
            .filter(|value| !value.is_empty())
            .unwrap_or("Lumen")
            .to_owned();
        let control_port = HostPorts::from_arguments(arguments)?.control_https;
        let owner_access = Self::owner_access(&owner_store, false);
        Ok(Self {
            owner_store,
            settings_path: paths.settings,
            applications_path: paths.applications,
            owner_access,
            navigation: WindowsNavigation::Overview,
            host_name,
            control_port,
        })
    }

    pub(crate) fn snapshot(&self) -> Result<WindowsAppSnapshot, String> {
        let settings = SettingsAuthority::open(
            self.settings_path.clone(),
            SettingsCapabilities::for_platform(SettingsHostPlatform::Windows),
        )
        .map_err(|error| format!("settings store failed: {error:?}"))?
        .snapshot();
        let applications = ApplicationCatalog::open(self.applications_path.clone())
            .and_then(|catalog| catalog.applications())
            .map_err(|error| format!("application catalog failed: {error:?}"))?;
        Ok(WindowsAppSnapshot {
            owner_access: self.owner_access.clone(),
            navigation: self.navigation,
            host_name: self.host_name.clone(),
            control_port: self.control_port,
            applications,
            settings: settings.settings,
        })
    }

    pub(crate) fn select(&mut self, navigation: WindowsNavigation) {
        self.navigation = navigation;
    }

    pub(crate) fn create_owner(
        &mut self,
        username: &str,
        password: &str,
        confirmation: &str,
    ) -> Result<(), OwnerAccountError> {
        if password != confirmation {
            return Err(OwnerAccountError::InvalidArgument);
        }
        self.owner_store.create_owner(username, password)?;
        self.owner_access = Self::owner_access(&self.owner_store, true);
        Ok(())
    }

    pub(crate) fn login(&mut self, password: &str) -> Result<(), OwnerAccountError> {
        let username = self.owner_store.username()?;
        self.owner_store.verify_owner(&username, password)?;
        self.owner_access = WindowsOwnerAccessState::Authenticated(username);
        Ok(())
    }

    pub(crate) fn lock(&mut self) {
        self.owner_access = Self::owner_access(&self.owner_store, false);
    }

    fn owner_access(store: &OwnerAccountStore, authenticated: bool) -> WindowsOwnerAccessState {
        match store.state() {
            LumenOwnerState::Uninitialized => WindowsOwnerAccessState::SetupRequired,
            LumenOwnerState::Ready => match store.username() {
                Ok(username) if authenticated => WindowsOwnerAccessState::Authenticated(username),
                Ok(username) => WindowsOwnerAccessState::LoginRequired(username),
                Err(_) => WindowsOwnerAccessState::Corrupt,
            },
            LumenOwnerState::Corrupt => WindowsOwnerAccessState::Corrupt,
            LumenOwnerState::Unavailable => WindowsOwnerAccessState::Unavailable,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(root: &std::path::Path) -> WindowsAppModel {
        WindowsAppModel {
            owner_store: OwnerAccountStore::open(root.join("owner-account.json")).unwrap(),
            settings_path: root.join("settings.json"),
            applications_path: root.join("apps.json"),
            owner_access: WindowsOwnerAccessState::SetupRequired,
            navigation: WindowsNavigation::Overview,
            host_name: "Studio".to_owned(),
            control_port: 47_990,
        }
    }

    #[test]
    fn owner_setup_login_and_lock_are_reduced_into_one_state_model() {
        let root = tempfile::tempdir().unwrap();
        let mut model = model(root.path());
        assert_eq!(
            model.snapshot().unwrap().owner_access,
            WindowsOwnerAccessState::SetupRequired
        );

        model
            .create_owner(
                "owner",
                "correct horse battery staple",
                "correct horse battery staple",
            )
            .unwrap();
        assert_eq!(
            model.snapshot().unwrap().owner_access,
            WindowsOwnerAccessState::Authenticated("owner".to_owned())
        );

        model.lock();
        assert_eq!(
            model.snapshot().unwrap().owner_access,
            WindowsOwnerAccessState::LoginRequired("owner".to_owned())
        );
        assert_eq!(
            model.login("wrong password"),
            Err(OwnerAccountError::AuthenticationFailed)
        );
        model.login("correct horse battery staple").unwrap();
    }

    #[test]
    fn snapshot_uses_windows_capabilities_and_tracks_navigation() {
        let root = tempfile::tempdir().unwrap();
        let mut model = model(root.path());
        model.select(WindowsNavigation::Applications);
        let snapshot = model.snapshot().unwrap();
        assert_eq!(snapshot.host_name, "Studio");
        assert_eq!(snapshot.navigation, WindowsNavigation::Applications);
        assert_eq!(snapshot.settings.general.name, "Lumen");
        assert!(snapshot.applications.is_empty());
    }

    #[test]
    fn navigation_indices_cover_the_exact_management_sidebar_order() {
        let expected = [
            WindowsNavigation::Overview,
            WindowsNavigation::Applications,
            WindowsNavigation::Security,
            WindowsNavigation::General,
            WindowsNavigation::Streaming,
            WindowsNavigation::Audio,
            WindowsNavigation::Input,
            WindowsNavigation::Network,
            WindowsNavigation::Advanced,
            WindowsNavigation::Diagnostics,
            WindowsNavigation::About,
        ];
        for (index, navigation) in expected.into_iter().enumerate() {
            assert_eq!(WindowsNavigation::from_index(index as i32), navigation);
            assert_eq!(navigation.index(), index as i32);
        }
    }

    #[test]
    fn native_arguments_compose_the_windows_app_model() {
        let root = tempfile::tempdir().unwrap();
        let mut values = crate::config::tests::valid_arguments();
        for value in &mut values {
            let replacement = if value.starts_with("file_apps=") {
                Some(root.path().join("apps.json"))
            } else if value.starts_with("credentials_file=") {
                Some(root.path().join("credentials.json"))
            } else if value.starts_with("file_state=") {
                Some(root.path().join("state.json"))
            } else {
                None
            };
            if let Some(path) = replacement {
                let key = value.split_once('=').unwrap().0;
                *value = format!("{key}={}", path.display());
            }
        }
        let arguments = HostArguments::parse(values).unwrap();
        let model = WindowsAppModel::from_arguments(&arguments).unwrap();
        let snapshot = model.snapshot().unwrap();
        assert_eq!(snapshot.control_port, 47_990);
        assert_eq!(snapshot.host_name, "Lumen");
    }
}
