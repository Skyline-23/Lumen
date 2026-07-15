use crate::{
    AppliedResources, LumenEngineStatus, LumenWorkspaceCommandKind, LumenWorkspaceState,
    RecoveryJournalError, RecoveryJournalLoad, RecoveryJournalStore, RecoveryPhase,
    WorkspaceEngine,
};

impl WorkspaceEngine {
    pub fn with_recovery_store(store: RecoveryJournalStore) -> Self {
        let mut engine = Self::default();
        engine.recovery_store = Some(store);
        engine
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
        self.resources = AppliedResources {
            snapshot: journal.phase.verification_required(),
            display: journal.virtual_display.is_some(),
            capture: journal.phase.capture_may_be_running(),
        };
        self.recovery_journal = Some(journal);
        self.state = LumenWorkspaceState::Stopping;
        let status = self.enqueue_next_cleanup();
        if status != LumenEngineStatus::Ok {
            self.last_failure = status;
            return status;
        }
        LumenEngineStatus::RecoveryRequired
    }

    pub(crate) fn schedule_recovery(&mut self) -> LumenEngineStatus {
        self.state = LumenWorkspaceState::Stopping;
        self.queued.clear();
        let status = self.enqueue_next_cleanup();
        if status != LumenEngineStatus::Ok {
            self.last_failure = status;
        }
        status
    }

    pub(crate) fn advance_cleanup(
        &mut self,
        completed: LumenWorkspaceCommandKind,
    ) -> LumenEngineStatus {
        let phase = match completed {
            LumenWorkspaceCommandKind::StopCapture => Some(RecoveryPhase::CaptureStopped),
            LumenWorkspaceCommandKind::RestoreWorkspace => Some(RecoveryPhase::RestorationVerified),
            LumenWorkspaceCommandKind::SnapshotWorkspace
            | LumenWorkspaceCommandKind::CreateVirtualDisplay
            | LumenWorkspaceCommandKind::ConfigureVirtualDisplay
            | LumenWorkspaceCommandKind::PromoteVirtualMain
            | LumenWorkspaceCommandKind::MoveTargetWindows
            | LumenWorkspaceCommandKind::ApplyIsolation
            | LumenWorkspaceCommandKind::StartCapture
            | LumenWorkspaceCommandKind::DestroyVirtualDisplay => None,
        };
        if let Some(phase) = phase {
            let status = self.persist_recovery_phase(phase);
            if status != LumenEngineStatus::Ok {
                return status;
            }
        }
        self.enqueue_next_cleanup()
    }

    pub(crate) fn record_cleanup_failure(&mut self, kind: LumenWorkspaceCommandKind) {
        match kind {
            LumenWorkspaceCommandKind::StopCapture => {
                self.resources.capture = false;
                let _ = self.enqueue_next_cleanup();
            }
            LumenWorkspaceCommandKind::RestoreWorkspace => {
                self.queued.clear();
            }
            LumenWorkspaceCommandKind::DestroyVirtualDisplay => {
                self.resources.display = false;
                self.finish_transition_if_ready();
            }
            LumenWorkspaceCommandKind::SnapshotWorkspace
            | LumenWorkspaceCommandKind::CreateVirtualDisplay
            | LumenWorkspaceCommandKind::ConfigureVirtualDisplay
            | LumenWorkspaceCommandKind::PromoteVirtualMain
            | LumenWorkspaceCommandKind::MoveTargetWindows
            | LumenWorkspaceCommandKind::ApplyIsolation
            | LumenWorkspaceCommandKind::StartCapture => {}
        }
    }

    fn persist_recovery_phase(&mut self, phase: RecoveryPhase) -> LumenEngineStatus {
        let Some(current) = self.recovery_journal.as_ref().cloned() else {
            return LumenEngineStatus::Ok;
        };
        let Some(store) = &self.recovery_store else {
            return LumenEngineStatus::StorageError;
        };
        let updated = current.with_phase(phase);
        if let Err(error) = store.update(&updated) {
            return journal_error_status(error);
        }
        self.recovery_journal = Some(updated);
        LumenEngineStatus::Ok
    }

    fn enqueue_next_cleanup(&mut self) -> LumenEngineStatus {
        if self.awaiting.is_some() || !self.queued.is_empty() {
            return LumenEngineStatus::Ok;
        }
        if self.resources.capture {
            self.enqueue(LumenWorkspaceCommandKind::StopCapture);
            return LumenEngineStatus::Ok;
        }
        if self.resources.snapshot {
            self.enqueue(LumenWorkspaceCommandKind::RestoreWorkspace);
            return LumenEngineStatus::Ok;
        }
        if self.recovery_journal.is_some() {
            let Some(store) = &self.recovery_store else {
                return LumenEngineStatus::StorageError;
            };
            if let Err(error) = store.delete() {
                return journal_error_status(error);
            }
            self.recovery_journal = None;
        }
        if self.resources.display {
            self.enqueue(LumenWorkspaceCommandKind::DestroyVirtualDisplay);
            return LumenEngineStatus::Ok;
        }
        self.finish_transition_if_ready();
        LumenEngineStatus::Ok
    }
}

const fn journal_error_status(error: RecoveryJournalError) -> LumenEngineStatus {
    match error {
        RecoveryJournalError::UnsupportedVersion(_) | RecoveryJournalError::InvalidField(_) => {
            LumenEngineStatus::CorruptData
        }
        RecoveryJournalError::AlreadyExists
        | RecoveryJournalError::Missing
        | RecoveryJournalError::Storage(_)
        | RecoveryJournalError::Serialization
        | RecoveryJournalError::StaleGeneration { .. }
        | RecoveryJournalError::SessionMismatch => LumenEngineStatus::StorageError,
    }
}
