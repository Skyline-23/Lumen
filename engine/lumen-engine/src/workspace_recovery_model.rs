use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const WORKSPACE_RECOVERY_SCHEMA_VERSION: u32 = 2;
const MAXIMUM_DISPLAY_COUNT: usize = 64;
const MAXIMUM_TARGET_PATH_COUNT: usize = 128;
const MAXIMUM_WINDOW_COUNT: usize = 512;
const MAXIMUM_IDENTIFIER_BYTES: usize = 512;

#[repr(C)]
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum WorkspacePlatform {
    Macos,
    Windows,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RecoveryPhase {
    SnapshotPersisted,
    VirtualCreated,
    VirtualConfigured,
    CaptureStarting,
    FirstFrameReady,
    VirtualPromoted,
    TargetWindowsMoved,
    IsolationStarted,
    Isolated,
    CaptureStopped,
    PhysicalRestored,
    RestorationVerified,
}

impl RecoveryPhase {
    pub(crate) const fn capture_may_be_running(self) -> bool {
        matches!(
            self,
            Self::CaptureStarting
                | Self::FirstFrameReady
                | Self::VirtualPromoted
                | Self::TargetWindowsMoved
                | Self::IsolationStarted
                | Self::Isolated
        )
    }

    pub(crate) const fn physical_restore_required(self) -> bool {
        !matches!(self, Self::PhysicalRestored | Self::RestorationVerified)
    }

    pub(crate) const fn verification_required(self) -> bool {
        !matches!(self, Self::RestorationVerified)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PhysicalDisplayMode {
    pub width: u32,
    pub height: u32,
    pub refresh_millihz: u32,
    pub bit_depth: u8,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PhysicalDisplayState {
    pub id: String,
    pub mode: PhysicalDisplayMode,
    pub origin_x: i32,
    pub origin_y: i32,
    pub mirror_master_id: Option<String>,
    pub enabled: bool,
    pub active: bool,
    pub online: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct WindowsAdapterLuid {
    pub high_part: i32,
    pub low_part: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct MacWorkspaceWindowState {
    pub process_id: i32,
    pub window_id: u32,
    pub origin_x: i32,
    pub origin_y: i32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PhysicalDisplayTopology {
    pub displays: Vec<PhysicalDisplayState>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub mac_windows: Vec<MacWorkspaceWindowState>,
    pub windows_adapter_luid: Option<WindowsAdapterLuid>,
    pub windows_target_paths: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct VirtualDisplayIdentity {
    pub id: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct WorkspaceRecoveryJournal {
    pub schema_version: u32,
    pub platform: WorkspacePlatform,
    pub generation: u64,
    pub session_id: String,
    pub phase: RecoveryPhase,
    pub virtual_display: Option<VirtualDisplayIdentity>,
    pub physical_topology: PhysicalDisplayTopology,
    pub timestamp_unix_ms: u64,
    pub capture_managed: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceRecoveryMetadata {
    pub platform: WorkspacePlatform,
    pub generation: u64,
    pub session_id: String,
    pub timestamp_unix_ms: u64,
    pub capture_managed: bool,
}

impl WorkspaceRecoveryJournal {
    pub fn new(
        metadata: WorkspaceRecoveryMetadata,
        physical_topology: PhysicalDisplayTopology,
    ) -> Result<Self, RecoveryJournalError> {
        let journal = Self {
            schema_version: WORKSPACE_RECOVERY_SCHEMA_VERSION,
            platform: metadata.platform,
            generation: metadata.generation,
            session_id: metadata.session_id,
            phase: RecoveryPhase::SnapshotPersisted,
            virtual_display: None,
            physical_topology,
            timestamp_unix_ms: metadata.timestamp_unix_ms,
            capture_managed: metadata.capture_managed,
        };
        journal.validate()?;
        Ok(journal)
    }

    pub fn with_phase(mut self, phase: RecoveryPhase) -> Self {
        self.phase = phase;
        self
    }

    pub fn with_virtual_display(mut self, identity: VirtualDisplayIdentity) -> Self {
        self.virtual_display = Some(identity);
        self
    }

    pub(crate) fn validate(&self) -> Result<(), RecoveryJournalError> {
        if self.schema_version != WORKSPACE_RECOVERY_SCHEMA_VERSION {
            return Err(RecoveryJournalError::UnsupportedVersion(
                self.schema_version,
            ));
        }
        validate_identifier("session_id", &self.session_id)?;
        if self.generation == 0 {
            return Err(RecoveryJournalError::InvalidField("generation"));
        }
        if self.physical_topology.displays.len() > MAXIMUM_DISPLAY_COUNT {
            return Err(RecoveryJournalError::InvalidField(
                "physical_topology.displays",
            ));
        }
        if self.physical_topology.windows_target_paths.len() > MAXIMUM_TARGET_PATH_COUNT {
            return Err(RecoveryJournalError::InvalidField(
                "physical_topology.windows_target_paths",
            ));
        }
        if self.physical_topology.mac_windows.len() > MAXIMUM_WINDOW_COUNT {
            return Err(RecoveryJournalError::InvalidField(
                "physical_topology.mac_windows",
            ));
        }
        if self.physical_topology.mac_windows.iter().any(|window| {
            window.process_id <= 0
                || window.window_id == 0
                || window.width == 0
                || window.height == 0
        }) {
            return Err(RecoveryJournalError::InvalidField(
                "physical_topology.mac_windows",
            ));
        }
        for display in &self.physical_topology.displays {
            validate_identifier("physical_topology.displays.id", &display.id)?;
            if let Some(mirror_master_id) = &display.mirror_master_id {
                validate_identifier(
                    "physical_topology.displays.mirror_master_id",
                    mirror_master_id,
                )?;
            }
        }
        for target_path in &self.physical_topology.windows_target_paths {
            validate_identifier("physical_topology.windows_target_paths", target_path)?;
        }
        if let Some(identity) = &self.virtual_display {
            validate_identifier("virtual_display.id", &identity.id)?;
        }
        Ok(())
    }
}

fn validate_identifier(field: &'static str, value: &str) -> Result<(), RecoveryJournalError> {
    if value.is_empty()
        || value.len() > MAXIMUM_IDENTIFIER_BYTES
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(RecoveryJournalError::InvalidField(field));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RecoveryJournalError {
    #[error("recovery journal already exists")]
    AlreadyExists,
    #[error("recovery journal is missing")]
    Missing,
    #[error("recovery journal storage failed during {0}")]
    Storage(&'static str),
    #[error("recovery journal serialization failed")]
    Serialization,
    #[error("recovery journal field is invalid: {0}")]
    InvalidField(&'static str),
    #[error("recovery journal schema version is unsupported: {0}")]
    UnsupportedVersion(u32),
    #[error("stale recovery generation {actual}; current generation is {expected}")]
    StaleGeneration { expected: u64, actual: u64 },
    #[error("recovery session does not match the active journal")]
    SessionMismatch,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryWarningCode {
    MalformedJournal,
    ChecksumMismatch,
    UnsupportedVersion,
    InvalidJournal,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceRecoveryWarning {
    pub code: RecoveryWarningCode,
    pub quarantined_path: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RecoveryJournalLoad {
    Missing,
    Verified(WorkspaceRecoveryJournal),
    Quarantined(WorkspaceRecoveryWarning),
}
