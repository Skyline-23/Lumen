use lumen_windows_driver_core::{
    lumen_driver_core_dispatch, lumen_driver_core_initial_state, CoreRequest, Operation, Status,
    ADAPTER_DEVICE_D3D11, STATE_MONITOR_ACTIVE, STATE_MONITOR_ORPHANED,
};

const FIRST_OWNER: u64 = 0xA11C_E001;
const SECOND_OWNER: u64 = 0xA11C_E002;
const MONITOR_ID: u64 = 0xD15A_0001;

fn initialized() -> lumen_windows_driver_core::CoreState {
    let state = lumen_driver_core_initial_state();
    let mut features = CoreRequest::new(Operation::RecordOsFeatures, 0, state.generation);
    features.arguments = [0x1A80, 1, 0, 0, 0];
    let features = lumen_driver_core_dispatch(state, features);
    let mut prepare = CoreRequest::new(Operation::PrepareAdapter, 0, state.generation);
    prepare.arguments = [0x0000_0002_0000_1234, ADAPTER_DEVICE_D3D11, 0, 0, 0];
    let prepared = lumen_driver_core_dispatch(features.state, prepare);
    let mut complete = CoreRequest::new(
        Operation::CompleteAdapterInitialization,
        0,
        prepared.state.generation,
    );
    complete.arguments[0] = 1;
    lumen_driver_core_dispatch(prepared.state, complete).state
}

fn claim_and_create(owner: u64) -> lumen_windows_driver_core::CoreState {
    let state = initialized();
    let claimed = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::ClaimOwner, owner, state.generation),
    );
    let mut create = CoreRequest::new(Operation::CreateMonitor, owner, claimed.state.generation);
    create.arguments = [MONITOR_ID, (1920 << 32) | 1080, 120_000, 0, 0];
    let created = lumen_driver_core_dispatch(claimed.state, create);
    assert_eq!(created.response.status, Status::Ok.raw());
    created.state
}

#[test]
fn owner_release_preserves_an_orphan_monitor_for_recovery() {
    // Given: the first owner has created a live monitor.
    let state = claim_and_create(FIRST_OWNER);

    // When: its file cleanup releases ownership without an explicit removal.
    let released = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::ReleaseOwner, FIRST_OWNER, state.generation),
    );

    // Then: ownership and encoder work are gone, but the monitor remains adoptable.
    assert_eq!(released.response.status, Status::Ok.raw());
    assert_eq!(released.state.owner_id, 0);
    assert_eq!(released.state.monitor_id, MONITOR_ID);
    assert_eq!(
        released.state.flags & (STATE_MONITOR_ACTIVE | STATE_MONITOR_ORPHANED),
        STATE_MONITOR_ACTIVE | STATE_MONITOR_ORPHANED
    );
}

#[test]
fn next_owner_queries_adopts_and_removes_the_orphan() {
    // Given: a crashed owner left one orphan monitor behind.
    let state = claim_and_create(FIRST_OWNER);
    let released = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::ReleaseOwner, FIRST_OWNER, state.generation),
    );
    let claimed = lumen_driver_core_dispatch(
        released.state,
        CoreRequest::new(
            Operation::ClaimOwner,
            SECOND_OWNER,
            released.state.generation,
        ),
    );

    // When: the next owner queries, adopts, and explicitly removes that monitor.
    let query = lumen_driver_core_dispatch(
        claimed.state,
        CoreRequest::new(
            Operation::QueryMonitor,
            SECOND_OWNER,
            claimed.state.generation,
        ),
    );
    let mut adopt = CoreRequest::new(
        Operation::AdoptMonitor,
        SECOND_OWNER,
        query.state.generation,
    );
    adopt.arguments[0] = query.response.values[0];
    let adopted = lumen_driver_core_dispatch(query.state, adopt);
    let mut remove = CoreRequest::new(
        Operation::RemoveMonitor,
        SECOND_OWNER,
        adopted.state.generation,
    );
    remove.arguments[0] = MONITOR_ID;
    let removed = lumen_driver_core_dispatch(adopted.state, remove);

    // Then: identity survives the query and adoption gates final removal.
    assert_eq!(query.response.status, Status::Ok.raw());
    assert_eq!(query.response.values[0], MONITOR_ID);
    assert_eq!(adopted.response.status, Status::Ok.raw());
    assert_eq!(adopted.state.flags & STATE_MONITOR_ORPHANED, 0);
    assert_eq!(removed.response.status, Status::Ok.raw());
    assert_eq!(removed.state.flags & STATE_MONITOR_ACTIVE, 0);
}

#[test]
fn repeated_crashes_keep_one_monitor_until_a_verified_owner_removes_it() {
    // Given: one live monitor is handed across multiple crashing owners.
    let mut state = claim_and_create(FIRST_OWNER);
    for owner in [FIRST_OWNER, SECOND_OWNER, SECOND_OWNER + 1] {
        let released = lumen_driver_core_dispatch(
            state,
            CoreRequest::new(Operation::ReleaseOwner, owner, state.generation),
        );
        let next_owner = owner + 1;
        let claimed = lumen_driver_core_dispatch(
            released.state,
            CoreRequest::new(Operation::ClaimOwner, next_owner, released.state.generation),
        );
        let mut adopt = CoreRequest::new(
            Operation::AdoptMonitor,
            next_owner,
            claimed.state.generation,
        );
        adopt.arguments[0] = MONITOR_ID;
        state = lumen_driver_core_dispatch(claimed.state, adopt).state;
    }

    // When: the final trusted owner queries the retained monitor.
    let query = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::QueryMonitor, SECOND_OWNER + 2, state.generation),
    );

    // Then: there is still exactly one stable monitor identity and no duplicate creation.
    assert_eq!(query.response.status, Status::Ok.raw());
    assert_eq!(query.response.values[0], MONITOR_ID);
    assert_eq!(
        query.state.flags & STATE_MONITOR_ACTIVE,
        STATE_MONITOR_ACTIVE
    );
}
