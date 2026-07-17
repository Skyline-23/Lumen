use std::time::{SystemTime, UNIX_EPOCH};

use crate::{
    workspace_command_recovery::journal_error_status, AppliedResources, LumenEngineStatus,
    LumenWorkspaceState, RecoveryJournalLoad, RecoveryJournalStore, VirtualDisplayIdentity,
    WorkspaceEngine, WorkspacePlatform, WorkspaceRecoveryMetadata,
};

impl WorkspaceEngine {
    pub fn with_recovery_store(store: RecoveryJournalStore, platform: WorkspacePlatform) -> Self {
        Self {
            recovery_store: Some(store),
            recovery_platform: Some(platform),
            ..Self::default()
        }
    }

    pub(crate) fn prepare_new_recovery_session(&mut self) -> LumenEngineStatus {
        let Some(platform) = self.recovery_platform else {
            return LumenEngineStatus::Ok;
        };
        let timestamp = match SystemTime::now().duration_since(UNIX_EPOCH) {
            Ok(duration) => u64::try_from(duration.as_millis()),
            Err(_) => return LumenEngineStatus::StorageError,
        };
        let Ok(timestamp_unix_ms) = timestamp else {
            return LumenEngineStatus::StorageError;
        };
        let session_id = format!("workspace-{timestamp_unix_ms}-{}", self.generation);
        self.recovery_metadata = Some(WorkspaceRecoveryMetadata {
            platform,
            generation: self.generation,
            session_id: session_id.clone(),
            timestamp_unix_ms,
            capture_managed: self.manage_capture,
        });
        self.virtual_display = Some(VirtualDisplayIdentity {
            id: format!("lumen-{session_id}"),
        });
        self.physical_topology = None;
        self.recovery_journal = None;
        LumenEngineStatus::Ok
    }

    pub(crate) fn recover_before_session(&mut self) -> LumenEngineStatus {
        let Some(store) = &self.recovery_store else {
            return LumenEngineStatus::Ok;
        };
        let journal = match store.load() {
            Ok(RecoveryJournalLoad::Missing) => return LumenEngineStatus::Ok,
            Ok(RecoveryJournalLoad::Verified(journal)) => journal,
            Ok(RecoveryJournalLoad::Quarantined(_)) => {
                self.last_failure = LumenEngineStatus::CorruptData;
                return LumenEngineStatus::CorruptData;
            }
            Err(error) => {
                let status = journal_error_status(error);
                self.last_failure = status;
                return status;
            }
        };

        self.generation = self.generation.max(journal.generation);
        self.next_sequence = 0;
        self.queued.clear();
        self.awaiting = None;
        self.cleanup_verification_failed = false;
        self.resources = AppliedResources {
            snapshot: journal.phase.verification_required(),
            display: journal.virtual_display.is_some(),
            capture: journal.capture_managed && journal.phase.capture_may_be_running(),
            physical_restored: !journal.phase.physical_restore_required(),
        };
        self.recovery_metadata = Some(WorkspaceRecoveryMetadata {
            platform: journal.platform,
            generation: journal.generation,
            session_id: journal.session_id.clone(),
            timestamp_unix_ms: journal.timestamp_unix_ms,
            capture_managed: journal.capture_managed,
        });
        self.physical_topology = Some(journal.physical_topology.clone());
        self.virtual_display = journal.virtual_display.clone();
        self.recovery_journal = Some(journal);
        self.state = LumenWorkspaceState::Stopping;
        let status = self.enqueue_next_cleanup();
        if status != LumenEngineStatus::Ok {
            self.last_failure = status;
            return status;
        }
        LumenEngineStatus::RecoveryRequired
    }
}
