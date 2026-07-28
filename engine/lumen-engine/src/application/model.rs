use std::collections::BTreeMap;

use serde::Serialize;

use crate::LumenEngineStatus;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CatalogError {
    InvalidArgument,
    Storage,
    Corrupt,
}

impl CatalogError {
    pub(super) fn status(&self) -> LumenEngineStatus {
        match self {
            Self::InvalidArgument => LumenEngineStatus::InvalidArgument,
            Self::Storage => LumenEngineStatus::StorageError,
            Self::Corrupt => LumenEngineStatus::CorruptData,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationDescriptor {
    pub id: u32,
    pub uuid: String,
    pub name: String,
    pub title: String,
    pub hdr_supported: bool,
    pub is_app_collector_game: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApplicationCommandPlan {
    pub run: String,
    pub undo: String,
    pub elevated: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApplicationLaunchPlan {
    pub id: u32,
    pub uuid: String,
    pub name: String,
    pub command: String,
    pub working_directory: String,
    pub output: String,
    pub image_path: String,
    pub environment: BTreeMap<String, String>,
    pub prep_commands: Vec<ApplicationCommandPlan>,
    pub state_commands: Vec<ApplicationCommandPlan>,
    pub detached_commands: Vec<String>,
    pub exclude_global_prep_commands: bool,
    pub exclude_global_state_commands: bool,
    pub elevated: bool,
    pub auto_detach: bool,
    pub wait_all: bool,
    pub exit_timeout_seconds: u32,
    pub virtual_display: bool,
    pub scale_percent: u32,
    pub use_app_identity: bool,
    pub per_client_app_identity: bool,
    pub terminate_on_pause: bool,
    pub gamepad: String,
}

impl ApplicationLaunchPlan {
    pub fn captures_desktop(&self) -> bool {
        self.command.is_empty() && self.detached_commands.is_empty()
    }
}
