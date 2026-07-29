use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub(super) struct AbandonableSession<T> {
    epoch: u32,
    retired: Arc<AtomicBool>,
    value: T,
}

impl<T> AbandonableSession<T> {
    pub(super) fn epoch(&self) -> u32 {
        self.epoch
    }

    pub(super) fn is_retired(&self) -> bool {
        self.retired.load(Ordering::Acquire)
    }

    pub(super) fn retirement_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.retired)
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
            retired: Arc::new(AtomicBool::new(false)),
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

    pub(super) fn retire(&self) -> Result<Option<Arc<AbandonableSession<T>>>, &'static str> {
        let session = self
            .current
            .lock()
            .map_err(|_| "abandonable session slot is poisoned")?
            .take();
        if let Some(session) = &session {
            session.retired.store(true, Ordering::Release);
        }
        Ok(session)
    }
}

#[cfg(test)]
mod tests {
    use super::AbandonableSessionSlot;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{mpsc, Arc};
    use std::time::{Duration, Instant};

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
}
