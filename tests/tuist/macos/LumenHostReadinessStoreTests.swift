import LumenAppArchitecture
import XCTest

final class LumenHostReadinessStoreTests: XCTestCase {
    func testRuntimeStatusReductionClearsRecoveredError() async {
        let store = LumenHostReadinessStore()

        await store.send(.runtimeStopped(message: "Stopped"))
        await store.send(.runtimeStatusChanged(runtime: true, video: true, audio: false))

        let state = await store.snapshot()
        XCTAssertTrue(state.runtimeRunning)
        XCTAssertTrue(state.videoCaptureRunning)
        XCTAssertFalse(state.audioCaptureRunning)
        XCTAssertNil(state.lastErrorMessage)
    }

    func testPermissionReductionDoesNotMutateRuntimeState() async {
        let initialState = LumenHostReadinessState(
            runtimeRunning: true,
            videoCaptureRunning: true,
            audioCaptureRunning: true
        )
        let store = LumenHostReadinessStore(initialState: initialState)

        await store.send(.permissionsChanged(accessibility: true, screenCapture: false))

        let state = await store.snapshot()
        XCTAssertTrue(state.runtimeRunning)
        XCTAssertTrue(state.videoCaptureRunning)
        XCTAssertTrue(state.audioCaptureRunning)
        XCTAssertTrue(state.accessibilityGranted)
        XCTAssertFalse(state.screenCaptureGranted)
    }

    func testStateStreamEmitsInitialAndReducedState() async {
        let store = LumenHostReadinessStore()
        let stream = await store.states()
        var iterator = stream.makeAsyncIterator()

        let initialState = await iterator.next()
        await store.send(.errorChanged("Failure"))
        let updatedState = await iterator.next()

        XCTAssertEqual(initialState, LumenHostReadinessState())
        XCTAssertEqual(updatedState?.lastErrorMessage, "Failure")
    }
}
