use std::future::Future;
use std::time::Duration;

use thiserror::Error;

use crate::{
    PhysicalDisplayTopology, RecoveryJournalError, RecoveryJournalLoad, RecoveryJournalStore,
    RecoveryPhase, VirtualDisplayIdentity, WorkspacePlatform, WorkspaceRecoveryJournal,
    WorkspaceRecoveryMetadata, WorkspaceRecoveryWarning,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceAdapterOperation {
    SnapshotWorkspace,
    CreateVirtualDisplay,
    ConfigureVirtualDisplay,
    StartCapture,
    IsolatePhysicalDisplays,
    StopCapture,
    RestorePhysicalDisplays,
    VerifyPhysicalDisplays,
    DestroyVirtualDisplay,
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
#[error("workspace adapter operation {operation:?} failed: {detail}")]
pub struct WorkspaceAdapterError {
    pub operation: WorkspaceAdapterOperation,
    pub detail: String,
}

pub trait WorkspacePlatformAdapter {
    fn snapshot_workspace(
        &mut self,
    ) -> impl Future<Output = Result<PhysicalDisplayTopology, WorkspaceAdapterError>> + Send;

    fn create_virtual_display(
        &mut self,
    ) -> impl Future<Output = Result<VirtualDisplayIdentity, WorkspaceAdapterError>> + Send;

    fn configure_virtual_display(
        &mut self,
        identity: &VirtualDisplayIdentity,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send;

    fn start_capture_until_first_frame(
        &mut self,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send;

    fn isolate_physical_displays(
        &mut self,
        topology: &PhysicalDisplayTopology,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send;

    fn stop_capture(&mut self) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send;

    fn restore_physical_displays(
        &mut self,
        topology: &PhysicalDisplayTopology,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send;

    fn verify_physical_displays(
        &mut self,
        topology: &PhysicalDisplayTopology,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send;

    fn destroy_virtual_display(
        &mut self,
        identity: &VirtualDisplayIdentity,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceRecoverySession {
    pub platform: WorkspacePlatform,
    pub session_id: String,
    pub timestamp_unix_ms: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceRecoveryOutcome {
    Clean,
    Recovered,
}

#[derive(Debug, Error)]
pub enum WorkspaceLifecycleError {
    #[error(transparent)]
    Journal(#[from] RecoveryJournalError),
    #[error(transparent)]
    Adapter(#[from] WorkspaceAdapterError),
    #[error("first encoded frame did not arrive within {timeout_millis} ms")]
    FirstFrameTimeout { timeout_millis: u64 },
    #[error("recovery journal was quarantined: {0:?}")]
    RecoveryWarning(WorkspaceRecoveryWarning),
    #[error("workspace session is already active")]
    SessionActive,
    #[error("workspace session is not active")]
    SessionInactive,
    #[error("workspace startup failed ({primary}); cleanup also failed ({cleanup})")]
    StartupCleanup { primary: String, cleanup: String },
}

pub struct RecoverableWorkspaceEngine<A> {
    adapter: A,
    store: RecoveryJournalStore,
    first_frame_timeout: Duration,
    generation: u64,
    active: Option<WorkspaceRecoveryJournal>,
}

impl<A: WorkspacePlatformAdapter> RecoverableWorkspaceEngine<A> {
    pub fn new(adapter: A, store: RecoveryJournalStore, first_frame_timeout: Duration) -> Self {
        Self {
            adapter,
            store,
            first_frame_timeout,
            generation: 0,
            active: None,
        }
    }

    pub fn adapter(&self) -> &A {
        &self.adapter
    }

    pub fn active_phase(&self) -> Option<RecoveryPhase> {
        self.active.as_ref().map(|journal| journal.phase)
    }

    pub async fn recover_before_session(
        &mut self,
    ) -> Result<WorkspaceRecoveryOutcome, WorkspaceLifecycleError> {
        if self.active.is_some() {
            return Err(WorkspaceLifecycleError::SessionActive);
        }
        let journal = match self.store.load()? {
            RecoveryJournalLoad::Missing => return Ok(WorkspaceRecoveryOutcome::Clean),
            RecoveryJournalLoad::Verified(journal) => journal,
            RecoveryJournalLoad::Quarantined(warning) => {
                return Err(WorkspaceLifecycleError::RecoveryWarning(warning));
            }
        };
        self.generation = self.generation.max(journal.generation);
        self.active = Some(journal);
        self.cleanup_active().await?;
        Ok(WorkspaceRecoveryOutcome::Recovered)
    }

    pub async fn start_session(
        &mut self,
        session: WorkspaceRecoverySession,
    ) -> Result<(), WorkspaceLifecycleError> {
        if self.active.is_some() {
            return Err(WorkspaceLifecycleError::SessionActive);
        }
        self.recover_before_session().await?;
        let topology = self.adapter.snapshot_workspace().await?;
        self.generation = self.generation.wrapping_add(1).max(1);
        let journal = WorkspaceRecoveryJournal::new(
            WorkspaceRecoveryMetadata {
                platform: session.platform,
                generation: self.generation,
                session_id: session.session_id,
                timestamp_unix_ms: session.timestamp_unix_ms,
                capture_managed: true,
            },
            topology,
        )?;
        self.store.create(&journal)?;
        self.active = Some(journal);

        if let Err(primary) = self.run_startup().await {
            return match self.cleanup_active().await {
                Ok(()) => Err(primary),
                Err(cleanup) => Err(WorkspaceLifecycleError::StartupCleanup {
                    primary: primary.to_string(),
                    cleanup: cleanup.to_string(),
                }),
            };
        }
        Ok(())
    }

    pub async fn stop_session(&mut self) -> Result<(), WorkspaceLifecycleError> {
        if self.active.is_none() {
            return Err(WorkspaceLifecycleError::SessionInactive);
        }
        self.cleanup_active().await
    }

    async fn run_startup(&mut self) -> Result<(), WorkspaceLifecycleError> {
        let virtual_display = self.adapter.create_virtual_display().await?;
        self.update_active(|journal| {
            journal
                .with_virtual_display(virtual_display.clone())
                .with_phase(RecoveryPhase::VirtualCreated)
        })?;
        self.adapter
            .configure_virtual_display(&virtual_display)
            .await?;
        self.update_phase(RecoveryPhase::VirtualConfigured)?;
        self.update_phase(RecoveryPhase::IsolationStarted)?;
        let topology = self.active_topology()?.clone();
        self.adapter.isolate_physical_displays(&topology).await?;
        self.update_phase(RecoveryPhase::Isolated)?;
        self.update_phase(RecoveryPhase::CaptureStarting)?;
        match tokio::time::timeout(
            self.first_frame_timeout,
            self.adapter.start_capture_until_first_frame(),
        )
        .await
        {
            Ok(result) => result?,
            Err(_) => {
                let timeout_millis =
                    u64::try_from(self.first_frame_timeout.as_millis()).unwrap_or(u64::MAX);
                return Err(WorkspaceLifecycleError::FirstFrameTimeout { timeout_millis });
            }
        }
        self.update_phase(RecoveryPhase::FirstFrameReady)?;
        Ok(())
    }

    async fn cleanup_active(&mut self) -> Result<(), WorkspaceLifecycleError> {
        let phase = self
            .active_phase()
            .ok_or(WorkspaceLifecycleError::SessionInactive)?;
        let mut stop_error = None;
        if phase.capture_may_be_running() {
            match self.adapter.stop_capture().await {
                Ok(()) => self.update_phase(RecoveryPhase::CaptureStopped)?,
                Err(error) => stop_error = Some(error),
            }
        }

        let phase = self
            .active_phase()
            .ok_or(WorkspaceLifecycleError::SessionInactive)?;
        let topology = self.active_topology()?.clone();
        if phase.physical_restore_required() {
            self.adapter.restore_physical_displays(&topology).await?;
            self.update_phase(RecoveryPhase::PhysicalRestored)?;
        }
        let phase = self
            .active_phase()
            .ok_or(WorkspaceLifecycleError::SessionInactive)?;
        if phase.verification_required() {
            self.adapter.verify_physical_displays(&topology).await?;
            self.update_phase(RecoveryPhase::RestorationVerified)?;
        }

        let virtual_display = self
            .active
            .as_ref()
            .and_then(|journal| journal.virtual_display.clone());
        self.store.delete()?;
        self.active = None;
        if let Some(identity) = virtual_display {
            self.adapter.destroy_virtual_display(&identity).await?;
        }
        match stop_error {
            Some(error) => Err(error.into()),
            None => Ok(()),
        }
    }

    fn active_topology(&self) -> Result<&PhysicalDisplayTopology, WorkspaceLifecycleError> {
        self.active
            .as_ref()
            .map(|journal| &journal.physical_topology)
            .ok_or(WorkspaceLifecycleError::SessionInactive)
    }

    fn update_phase(&mut self, phase: RecoveryPhase) -> Result<(), WorkspaceLifecycleError> {
        self.update_active(|journal| journal.with_phase(phase))
    }

    fn update_active(
        &mut self,
        update: impl FnOnce(WorkspaceRecoveryJournal) -> WorkspaceRecoveryJournal,
    ) -> Result<(), WorkspaceLifecycleError> {
        let current = self
            .active
            .as_ref()
            .cloned()
            .ok_or(WorkspaceLifecycleError::SessionInactive)?;
        let updated = update(current);
        self.store.update(&updated)?;
        self.active = Some(updated);
        Ok(())
    }
}
