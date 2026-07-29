use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

const SESSION_ACTIVE: u8 = 0;
const SESSION_COMMITTING: u8 = 1;
const SESSION_RETIRED: u8 = 2;
const SESSION_RETIRING: u8 = 3;

pub(super) struct SessionRetirementGate {
    state: AtomicU8,
    retirement_wait: Mutex<()>,
    retirement_changed: Condvar,
}

struct SessionCommit<'a> {
    gate: &'a SessionRetirementGate,
}

impl Drop for SessionCommit<'_> {
    fn drop(&mut self) {
        self.gate.finish_commit();
    }
}

impl Default for SessionRetirementGate {
    fn default() -> Self {
        Self {
            state: AtomicU8::new(SESSION_ACTIVE),
            retirement_wait: Mutex::new(()),
            retirement_changed: Condvar::new(),
        }
    }
}

impl SessionRetirementGate {
    pub(super) fn is_retired(&self) -> bool {
        matches!(
            self.state.load(Ordering::Acquire),
            SESSION_RETIRING | SESSION_RETIRED
        )
    }

    pub(super) fn commit_if_active(&self, commit: impl FnOnce()) -> bool {
        if self
            .state
            .compare_exchange(
                SESSION_ACTIVE,
                SESSION_COMMITTING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            return false;
        }
        let _commit = SessionCommit { gate: self };
        commit();
        true
    }

    fn finish_commit(&self) {
        match self.state.compare_exchange(
            SESSION_COMMITTING,
            SESSION_ACTIVE,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => {}
            Err(SESSION_RETIRING) => {
                self.state.store(SESSION_RETIRED, Ordering::Release);
                self.retirement_changed.notify_all();
            }
            Err(_) => {}
        }
    }

    pub(super) fn retire(&self) {
        let mut state = self.state.load(Ordering::Acquire);
        loop {
            match state {
                SESSION_ACTIVE => match self.state.compare_exchange_weak(
                    SESSION_ACTIVE,
                    SESSION_RETIRED,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => return,
                    Err(current) => state = current,
                },
                SESSION_COMMITTING => match self.state.compare_exchange_weak(
                    SESSION_COMMITTING,
                    SESSION_RETIRING,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => {
                        let mut wait = self
                            .retirement_wait
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        while self.state.load(Ordering::Acquire) == SESSION_RETIRING {
                            wait = self
                                .retirement_changed
                                .wait(wait)
                                .unwrap_or_else(|poisoned| poisoned.into_inner());
                        }
                        return;
                    }
                    Err(current) => state = current,
                },
                SESSION_RETIRING => {
                    let mut wait = self
                        .retirement_wait
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    while self.state.load(Ordering::Acquire) == SESSION_RETIRING {
                        wait = self
                            .retirement_changed
                            .wait(wait)
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                    }
                    return;
                }
                SESSION_RETIRED => return,
                _ => unreachable!("unknown session retirement state"),
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FrameDeliveryState {
    Paused,
    Running,
    Retired,
}

pub(super) struct FrameDeliveryOwnership {
    state: Mutex<FrameDeliveryState>,
}

impl Default for FrameDeliveryOwnership {
    fn default() -> Self {
        Self {
            state: Mutex::new(FrameDeliveryState::Paused),
        }
    }
}

impl FrameDeliveryOwnership {
    pub(super) fn start_with(
        &self,
        start: impl FnOnce() -> Result<(), String>,
    ) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "frame delivery ownership is poisoned".to_owned())?;
        match *state {
            FrameDeliveryState::Paused => {
                start()?;
                *state = FrameDeliveryState::Running;
                Ok(())
            }
            FrameDeliveryState::Running => Ok(()),
            FrameDeliveryState::Retired => {
                Err("retired frame delivery cannot be restarted".to_owned())
            }
        }
    }

    pub(super) fn pause_with(
        &self,
        stop: impl FnOnce() -> Result<(), String>,
    ) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "frame delivery ownership is poisoned".to_owned())?;
        if *state == FrameDeliveryState::Running {
            stop()?;
            *state = FrameDeliveryState::Paused;
        }
        Ok(())
    }

    pub(super) fn retire_with(
        &self,
        stop: impl FnOnce() -> Result<(), String>,
    ) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "frame delivery ownership is poisoned".to_owned())?;
        match *state {
            FrameDeliveryState::Running => {
                stop()?;
                *state = FrameDeliveryState::Retired;
            }
            FrameDeliveryState::Paused => *state = FrameDeliveryState::Retired,
            FrameDeliveryState::Retired => (),
        }
        Ok(())
    }
}

pub(super) struct AbandonableSession<T> {
    epoch: u32,
    retirement_gate: Arc<SessionRetirementGate>,
    value: T,
}

impl<T> AbandonableSession<T> {
    pub(super) fn epoch(&self) -> u32 {
        self.epoch
    }

    pub(super) fn is_retired(&self) -> bool {
        self.retirement_gate.is_retired()
    }

    pub(super) fn retirement_gate(&self) -> Arc<SessionRetirementGate> {
        Arc::clone(&self.retirement_gate)
    }

    pub(super) fn value(&self) -> &T {
        &self.value
    }
}

pub(super) struct AbandonableSessionSlot<T> {
    current: Mutex<Option<Arc<AbandonableSession<T>>>>,
}

impl<T> Default for AbandonableSessionSlot<T> {
    fn default() -> Self {
        Self {
            current: Mutex::new(None),
        }
    }
}

impl<T> AbandonableSessionSlot<T> {
    pub(super) fn install(
        &self,
        epoch: u32,
        value: T,
    ) -> Result<Arc<AbandonableSession<T>>, &'static str> {
        let mut current = self
            .current
            .lock()
            .map_err(|_| "abandonable session slot is poisoned")?;
        if current.is_some() {
            return Err("abandonable session slot is occupied");
        }
        let session = Arc::new(AbandonableSession {
            epoch,
            retirement_gate: Arc::new(SessionRetirementGate::default()),
            value,
        });
        *current = Some(Arc::clone(&session));
        Ok(session)
    }

    pub(super) fn snapshot(&self, epoch: u32) -> Result<Arc<AbandonableSession<T>>, &'static str> {
        let current = self
            .current
            .lock()
            .map_err(|_| "abandonable session slot is poisoned")?;
        current
            .as_ref()
            .filter(|session| session.epoch() == epoch && !session.is_retired())
            .cloned()
            .ok_or("abandonable session epoch is not active")
    }

    pub(super) fn current(&self) -> Result<Option<Arc<AbandonableSession<T>>>, &'static str> {
        self.current
            .lock()
            .map(|current| current.clone())
            .map_err(|_| "abandonable session slot is poisoned")
    }

    #[cfg(test)]
    pub(super) fn retire(&self) -> Result<Option<Arc<AbandonableSession<T>>>, &'static str> {
        let session = self.begin_retire()?;
        if let Some(session) = &session {
            self.finish_retire(session.epoch())?;
        }
        Ok(session)
    }

    pub(super) fn begin_retire(&self) -> Result<Option<Arc<AbandonableSession<T>>>, &'static str> {
        let session = self
            .current
            .lock()
            .map_err(|_| "abandonable session slot is poisoned")?
            .clone();
        if let Some(session) = &session {
            session.retirement_gate.retire();
        }
        Ok(session)
    }

    pub(super) fn try_retire(
        &self,
        cleanup: impl FnOnce(&AbandonableSession<T>) -> Result<(), String>,
    ) -> Result<(), String> {
        let Some(session) = self.begin_retire().map_err(str::to_owned)? else {
            return Ok(());
        };
        cleanup(&session)?;
        self.finish_retire(session.epoch()).map_err(str::to_owned)
    }

    pub(super) fn finish_retire(&self, epoch: u32) -> Result<(), &'static str> {
        let mut current = self
            .current
            .lock()
            .map_err(|_| "abandonable session slot is poisoned")?;
        match current.as_ref() {
            Some(session) if session.epoch() == epoch && session.is_retired() => {
                current.take();
                Ok(())
            }
            Some(_) => Err("abandonable session retirement does not match the current epoch"),
            None => Ok(()),
        }
    }
}

pub(super) struct RetiredWorkerRegistry {
    capacity: usize,
    workers: Mutex<Vec<JoinHandle<()>>>,
}

impl RetiredWorkerRegistry {
    pub(super) fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "retired worker capacity must be positive");
        Self {
            capacity,
            workers: Mutex::new(Vec::with_capacity(capacity)),
        }
    }

    pub(super) fn ensure_capacity(&self) -> Result<(), String> {
        let mut workers = self
            .workers
            .lock()
            .map_err(|_| "retired worker registry is poisoned".to_owned())?;
        reap_finished_workers(&mut workers);
        if workers.len() >= self.capacity {
            return Err(format!(
                "retired worker registry reached fail-closed capacity {}",
                self.capacity
            ));
        }
        Ok(())
    }

    pub(super) fn insert(&self, worker: JoinHandle<()>) -> Result<(), (String, JoinHandle<()>)> {
        let mut workers = match self.workers.lock() {
            Ok(workers) => workers,
            Err(_) => {
                return Err(("retired worker registry is poisoned".to_owned(), worker));
            }
        };
        reap_finished_workers(&mut workers);
        if worker.is_finished() {
            let _ = worker.join();
            return Ok(());
        }
        if workers.len() >= self.capacity {
            return Err((
                format!(
                    "retired worker registry reached fail-closed capacity {}",
                    self.capacity
                ),
                worker,
            ));
        }
        workers.push(worker);
        Ok(())
    }
}

fn reap_finished_workers(workers: &mut Vec<JoinHandle<()>>) {
    let mut pending = Vec::with_capacity(workers.len());
    for worker in workers.drain(..) {
        if worker.is_finished() {
            let _ = worker.join();
        } else {
            pending.push(worker);
        }
    }
    *workers = pending;
}

#[cfg(test)]
mod tests {
    use super::{
        AbandonableSessionSlot, FrameDeliveryOwnership, RetiredWorkerRegistry,
        SessionRetirementGate,
    };
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::{Duration, Instant};

    #[test]
    fn retired_epoch_cannot_commit_a_late_success() {
        let gate = Arc::new(SessionRetirementGate::default());
        let persisted = Arc::new(AtomicUsize::new(0));
        let (applied_send, applied_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let worker_gate = Arc::clone(&gate);
        let worker_persisted = Arc::clone(&persisted);
        let worker = std::thread::spawn(move || {
            applied_send.send(()).unwrap();
            release_receive.recv().unwrap();
            worker_gate.commit_if_active(|| {
                worker_persisted.fetch_add(1, Ordering::AcqRel);
            })
        });

        applied_receive.recv().unwrap();
        gate.retire();
        release_send.send(()).unwrap();

        assert!(!worker.join().unwrap());
        assert_eq!(persisted.load(Ordering::Acquire), 0);
    }

    #[test]
    fn active_epoch_commits_one_success() {
        let gate = SessionRetirementGate::default();
        let persisted = AtomicUsize::new(0);
        assert!(gate.commit_if_active(|| {
            persisted.fetch_add(1, Ordering::AcqRel);
        }));
        assert_eq!(persisted.load(Ordering::Acquire), 1);
        assert!(!gate.is_retired());
    }

    #[test]
    fn retirement_fences_a_paused_commit_before_replacement_publication() {
        let gate = Arc::new(SessionRetirementGate::default());
        let publications = Arc::new(Mutex::new(Vec::new()));
        let (entered_send, entered_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let old_gate = Arc::clone(&gate);
        let old_publications = Arc::clone(&publications);
        let old = std::thread::spawn(move || {
            assert!(old_gate.commit_if_active(|| {
                entered_send.send(()).unwrap();
                release_receive.recv().unwrap();
                old_publications.lock().unwrap().push("old");
            }));
        });

        entered_receive.recv().unwrap();
        let retiring_gate = Arc::clone(&gate);
        let replacement_publications = Arc::clone(&publications);
        let (retired_send, retired_receive) = mpsc::sync_channel(1);
        let replacement = std::thread::spawn(move || {
            retiring_gate.retire();
            retired_send.send(()).unwrap();
            replacement_publications.lock().unwrap().push("new");
        });
        assert_eq!(retired_receive.try_recv(), Err(mpsc::TryRecvError::Empty));

        release_send.send(()).unwrap();
        retired_receive.recv().unwrap();
        old.join().unwrap();
        replacement.join().unwrap();

        assert!(gate.is_retired());
        assert_eq!(publications.lock().unwrap().as_slice(), ["old", "new"]);
    }

    #[test]
    fn stalled_policy_allows_bounded_stop_and_isolated_replacement_epoch() {
        let slot = Arc::new(AbandonableSessionSlot::default());
        let old_mutations = Arc::new(AtomicUsize::new(0));
        let old = slot.install(7, Arc::clone(&old_mutations)).unwrap();
        let policy = slot.snapshot(7).unwrap();
        let (entered_send, entered_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let stalled_policy = std::thread::spawn(move || {
            entered_send.send(()).unwrap();
            release_receive.recv().unwrap();
            policy.value().fetch_add(1, Ordering::AcqRel);
        });

        entered_receive.recv().unwrap();
        let stop_started = Instant::now();
        let retired = slot.retire().unwrap().unwrap();
        assert!(stop_started.elapsed() < Duration::from_millis(100));
        assert!(retired.is_retired());
        assert!(slot.snapshot(7).is_err());

        let replacement_mutations = Arc::new(AtomicUsize::new(0));
        let replacement = slot.install(8, Arc::clone(&replacement_mutations)).unwrap();
        assert_eq!(replacement.epoch(), 8);

        release_send.send(()).unwrap();
        stalled_policy.join().unwrap();
        assert_eq!(old.value().load(Ordering::Acquire), 1);
        assert_eq!(replacement.value().load(Ordering::Acquire), 0);
    }

    #[test]
    fn failed_cleanup_retains_retired_session_for_successful_retry() {
        let slot = AbandonableSessionSlot::default();
        let attempts = Arc::new(AtomicUsize::new(0));
        let installed = slot.install(9, Arc::clone(&attempts)).unwrap();

        let first_result = slot.try_retire(|session| {
            if session.value().fetch_add(1, Ordering::AcqRel) == 0 {
                Err("injected capture stop failure".to_owned())
            } else {
                Ok(())
            }
        });
        assert_eq!(
            first_result,
            Err("injected capture stop failure".to_owned())
        );
        let retained = slot.current().unwrap().unwrap();
        assert!(Arc::ptr_eq(&installed, &retained));
        assert!(retained.is_retired());

        let retry_result = slot.try_retire(|session| {
            if session.value().fetch_add(1, Ordering::AcqRel) == 0 {
                Err("injected capture stop failure".to_owned())
            } else {
                Ok(())
            }
        });
        assert_eq!(retry_result, Ok(()));
        assert!(slot.current().unwrap().is_none());
        assert_eq!(attempts.load(Ordering::Acquire), 2);
    }

    #[test]
    fn repeated_stalled_workers_hit_visible_fail_closed_capacity() {
        let registry = RetiredWorkerRegistry::new(2);
        let mut releases = Vec::new();
        for _ in 0..2 {
            let (release_send, release_receive) = mpsc::sync_channel(1);
            releases.push(release_send);
            registry
                .insert(std::thread::spawn(move || {
                    release_receive.recv().unwrap();
                }))
                .unwrap();
        }

        let error = registry.ensure_capacity().unwrap_err();
        assert!(error.contains("fail-closed capacity 2"));

        for release in releases {
            release.send(()).unwrap();
        }
        let deadline = Instant::now() + Duration::from_secs(1);
        while registry.ensure_capacity().is_err() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        registry.ensure_capacity().unwrap();
    }

    #[test]
    fn retired_old_worker_cannot_stop_replacement_frame_delivery() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let old = Arc::new(FrameDeliveryOwnership::default());
        old.start_with({
            let events = Arc::clone(&events);
            move || {
                events.lock().unwrap().push("start-old");
                Ok(())
            }
        })
        .unwrap();
        let (entered_send, entered_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let stalled_old = Arc::clone(&old);
        let old_worker = std::thread::spawn(move || {
            entered_send.send(()).unwrap();
            release_receive.recv().unwrap();
            stalled_old
                .pause_with(|| panic!("retired old worker issued a late STOP_ENCODER"))
                .unwrap();
        });

        entered_receive.recv().unwrap();
        old.retire_with({
            let events = Arc::clone(&events);
            move || {
                events.lock().unwrap().push("stop-old");
                Ok(())
            }
        })
        .unwrap();
        let replacement = FrameDeliveryOwnership::default();
        replacement
            .start_with({
                let events = Arc::clone(&events);
                move || {
                    events.lock().unwrap().push("start-new");
                    Ok(())
                }
            })
            .unwrap();

        release_send.send(()).unwrap();
        old_worker.join().unwrap();
        assert_eq!(
            events.lock().unwrap().as_slice(),
            ["start-old", "stop-old", "start-new"]
        );
        assert!(old.start_with(|| Ok(())).is_err());
    }

    #[test]
    fn failed_frame_delivery_retire_remains_retryable() {
        let ownership = FrameDeliveryOwnership::default();
        ownership.start_with(|| Ok(())).unwrap();
        let attempts = AtomicUsize::new(0);

        assert_eq!(
            ownership.retire_with(|| {
                attempts.fetch_add(1, Ordering::AcqRel);
                Err("injected STOP_ENCODER failure".to_owned())
            }),
            Err("injected STOP_ENCODER failure".to_owned())
        );
        ownership
            .retire_with(|| {
                attempts.fetch_add(1, Ordering::AcqRel);
                Ok(())
            })
            .unwrap();
        ownership
            .pause_with(|| panic!("retired capture issued another STOP_ENCODER"))
            .unwrap();
        assert_eq!(attempts.load(Ordering::Acquire), 2);
    }
}
