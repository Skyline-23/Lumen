use crate::{
    LumenEngineStatus, LumenWorkspaceCommandKind, LumenWorkspaceState, PhysicalDisplayTopology,
    RecoveryJournalError, RecoveryPhase, WorkspaceCommandPayload, WorkspaceEngine,
    WorkspaceRecoveryJournal,
};

impl WorkspaceEngine {
    pub(crate) fn prepare_command(&mut self, kind: LumenWorkspaceCommandKind) -> LumenEngineStatus {
        match kind {
            LumenWorkspaceCommandKind::StartCapture => {
                self.persist_recovery_phase(RecoveryPhase::CaptureStarting)
            }
            LumenWorkspaceCommandKind::ApplyIsolation => {
                self.persist_recovery_phase(RecoveryPhase::IsolationStarted)
            }
            LumenWorkspaceCommandKind::SnapshotWorkspace
            | LumenWorkspaceCommandKind::CreateVirtualDisplay
            | LumenWorkspaceCommandKind::ConfigureVirtualDisplay
            | LumenWorkspaceCommandKind::PromoteVirtualMain
            | LumenWorkspaceCommandKind::MoveTargetWindows
            | LumenWorkspaceCommandKind::StopCapture
            | LumenWorkspaceCommandKind::RestoreWorkspace
            | LumenWorkspaceCommandKind::VerifyPhysicalDisplays
            | LumenWorkspaceCommandKind::DestroyVirtualDisplay => LumenEngineStatus::Ok,
        }
    }

    pub(crate) fn record_command_success(
        &mut self,
        kind: LumenWorkspaceCommandKind,
        payload: WorkspaceCommandPayload,
    ) -> LumenEngineStatus {
        match (kind, payload) {
            (
                LumenWorkspaceCommandKind::SnapshotWorkspace,
                WorkspaceCommandPayload::PhysicalTopology(topology),
            ) => self.record_snapshot(topology),
            (
                LumenWorkspaceCommandKind::CreateVirtualDisplay,
                WorkspaceCommandPayload::VirtualDisplayIdentity(identity),
            ) if self.virtual_display.as_ref() == Some(&identity) => {
                self.resources.display = true;
                self.persist_recovery_phase(RecoveryPhase::VirtualCreated)
            }
            (LumenWorkspaceCommandKind::ConfigureVirtualDisplay, WorkspaceCommandPayload::None) => {
                self.persist_recovery_phase(RecoveryPhase::VirtualConfigured)
            }
            (LumenWorkspaceCommandKind::PromoteVirtualMain, WorkspaceCommandPayload::None) => {
                self.persist_recovery_phase(RecoveryPhase::VirtualPromoted)
            }
            (LumenWorkspaceCommandKind::MoveTargetWindows, WorkspaceCommandPayload::None) => {
                self.persist_recovery_phase(RecoveryPhase::TargetWindowsMoved)
            }
            (LumenWorkspaceCommandKind::ApplyIsolation, WorkspaceCommandPayload::None) => {
                self.persist_recovery_phase(RecoveryPhase::Isolated)
            }
            (LumenWorkspaceCommandKind::StartCapture, WorkspaceCommandPayload::None) => {
                self.resources.capture = true;
                self.persist_recovery_phase(RecoveryPhase::FirstFrameReady)
            }
            (LumenWorkspaceCommandKind::StopCapture, WorkspaceCommandPayload::None) => {
                self.resources.capture = false;
                self.persist_recovery_phase(RecoveryPhase::CaptureStopped)
            }
            (LumenWorkspaceCommandKind::RestoreWorkspace, WorkspaceCommandPayload::None) => {
                self.resources.physical_restored = true;
                self.persist_recovery_phase(RecoveryPhase::PhysicalRestored)
            }
            (LumenWorkspaceCommandKind::VerifyPhysicalDisplays, WorkspaceCommandPayload::None) => {
                let status = self.persist_recovery_phase(RecoveryPhase::RestorationVerified);
                if status == LumenEngineStatus::Ok {
                    self.resources.snapshot = false;
                }
                status
            }
            (LumenWorkspaceCommandKind::DestroyVirtualDisplay, WorkspaceCommandPayload::None) => {
                self.resources.display = false;
                self.virtual_display = None;
                LumenEngineStatus::Ok
            }
            _ => LumenEngineStatus::InvalidArgument,
        }
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
        _completed: LumenWorkspaceCommandKind,
    ) -> LumenEngineStatus {
        self.enqueue_next_cleanup()
    }

    pub(crate) fn record_cleanup_failure(&mut self, kind: LumenWorkspaceCommandKind) {
        match kind {
            LumenWorkspaceCommandKind::StopCapture => {
                self.resources.capture = false;
                let _ = self.enqueue_next_cleanup();
            }
            LumenWorkspaceCommandKind::RestoreWorkspace
            | LumenWorkspaceCommandKind::VerifyPhysicalDisplays => self.queued.clear(),
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

    fn record_snapshot(&mut self, topology: PhysicalDisplayTopology) -> LumenEngineStatus {
        self.resources.snapshot = true;
        self.resources.physical_restored = false;
        self.physical_topology = Some(topology.clone());
        let Some(store) = &self.recovery_store else {
            return LumenEngineStatus::Ok;
        };
        let (Some(metadata), Some(identity)) =
            (self.recovery_metadata.clone(), self.virtual_display.clone())
        else {
            return LumenEngineStatus::InvalidState;
        };
        let journal = match WorkspaceRecoveryJournal::new(metadata, topology) {
            Ok(journal) => journal.with_virtual_display(identity),
            Err(error) => return journal_error_status(error),
        };
        if let Err(error) = store.create(&journal) {
            return journal_error_status(error);
        }
        self.recovery_journal = Some(journal);
        LumenEngineStatus::Ok
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

    pub(crate) fn enqueue_next_cleanup(&mut self) -> LumenEngineStatus {
        if self.awaiting.is_some() || !self.queued.is_empty() {
            return LumenEngineStatus::Ok;
        }
        if self.resources.capture {
            self.enqueue(LumenWorkspaceCommandKind::StopCapture);
            return LumenEngineStatus::Ok;
        }
        if self.resources.snapshot && !self.resources.physical_restored {
            self.enqueue(LumenWorkspaceCommandKind::RestoreWorkspace);
            return LumenEngineStatus::Ok;
        }
        if self.resources.snapshot {
            self.enqueue(LumenWorkspaceCommandKind::VerifyPhysicalDisplays);
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

pub(crate) const fn journal_error_status(error: RecoveryJournalError) -> LumenEngineStatus {
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
