use std::time::Duration;

use super::*;
use crate::workspace_recovery_tests::{runtime, session, FakeWorkspaceAdapter};

#[test]
fn cancelled_startup_is_recovered_by_the_next_engine() {
    // Given: startup is cancelled while capture waits indefinitely for its first frame.
    let directory = tempfile::tempdir().unwrap();
    let journal_path = directory.path().join("display-recovery.json");
    let (started_tx, started_rx) = tokio::sync::oneshot::channel();
    let adapter = FakeWorkspaceAdapter {
        hang_before_first_frame: true,
        first_frame_started: Some(started_tx),
        ..FakeWorkspaceAdapter::default()
    };
    let store = RecoveryJournalStore::new(journal_path.clone());
    let engine = RecoverableWorkspaceEngine::new(adapter, store, Duration::from_secs(30));

    // When: the owner task is cancelled and a new engine resumes from the durable phase.
    runtime().block_on(async {
        let mut interrupted_engine = engine;
        let task = tokio::spawn(async move { interrupted_engine.start_session(session()).await });
        started_rx.await.unwrap();
        task.abort();
        let _ = task.await;
    });
    let store = RecoveryJournalStore::new(journal_path.clone());
    let mut resumed = RecoverableWorkspaceEngine::new(
        FakeWorkspaceAdapter::default(),
        store,
        Duration::from_secs(1),
    );
    runtime()
        .block_on(resumed.recover_before_session())
        .unwrap();

    // Then: recovery stops capture, verifies physical topology, and clears the journal.
    assert_eq!(
        resumed.adapter().events,
        vec![
            "stop-capture",
            "restore-physical",
            "verify-physical",
            "destroy-virtual"
        ]
    );
    assert!(!journal_path.exists());
}
