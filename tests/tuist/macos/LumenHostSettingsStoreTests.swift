import LumenMacBridge
import XCTest

final class LumenHostSettingsStoreTests: XCTestCase {
    func testDefaultsMatchNativeHostContract() async throws {
        let suiteName = "LumenHostSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = try LumenHostSettingsStore(suiteName: suiteName)
        let settings = try await store.snapshot()

        XCTAssertEqual(settings.workspacePolicy, .coexist)
        XCTAssertFalse(settings.systemAuthenticationEnabled)
        XCTAssertTrue(settings.discoveryEnabled)
        XCTAssertTrue(settings.deviceEnrollmentEnabled)
        XCTAssertTrue(settings.streamAudio)
        XCTAssertTrue(settings.keyboardInput)
        XCTAssertTrue(settings.mouseInput)
        XCTAssertTrue(settings.controllerInput)
        XCTAssertEqual(settings.addressFamily, .ipv4)
        XCTAssertEqual(settings.port, 47_989)
        XCTAssertFalse(settings.upnpEnabled)
        XCTAssertEqual(settings.lanEncryption, .disabled)
        XCTAssertEqual(settings.wanEncryption, .opportunistic)
        XCTAssertEqual(settings.pingTimeoutMilliseconds, 10_000)
        XCTAssertEqual(settings.fecPercentage, 20)
        XCTAssertEqual(settings.logLevel, .info)
    }

    func testCompleteSnapshotPersistsAndBuildsRuntimeArguments() async throws {
        let suiteName = "LumenHostSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = try LumenHostSettingsStore(suiteName: suiteName)
        var settings = try await store.snapshot()
        settings.workspacePolicy = .promoteVirtualMain
        settings.systemAuthenticationEnabled = true
        settings.name = "Studio Host"
        settings.discoveryEnabled = false
        settings.deviceEnrollmentEnabled = false
        settings.notifyPreReleases = true
        settings.globalPrepCommands = [LumenPrepCommand(run: "prepare", undo: "restore")]
        settings.globalStateCommands = [LumenPrepCommand(run: "state-on", undo: "state-off")]
        settings.serverCommands = [LumenServerCommand(name: "Wake", command: "wake-host")]
        settings.adapterSelector = "automatic"
        settings.outputSelector = "automatic"
        settings.audioSink = "system-default"
        settings.streamAudio = false
        settings.keyboardInput = false
        settings.mouseInput = false
        settings.controllerInput = false
        settings.controllerBackButtonTimeoutMilliseconds = 750
        settings.mapRightAltToWindowsKey = true
        settings.highResolutionScrolling = false
        settings.nativePenAndTouch = false
        settings.rumbleForwarding = false
        settings.addressFamily = .dualStack
        settings.port = 48_989
        settings.upnpEnabled = true
        settings.remoteAccessScope = .anywhere
        settings.externalIPMode = .disabled
        settings.lanEncryption = .required
        settings.wanEncryption = .required
        settings.pingTimeoutMilliseconds = 15_000
        settings.fecPercentage = 30
        settings.logLevel = .debug

        try await store.save(settings)

        let reopened = try LumenHostSettingsStore(suiteName: suiteName)
        let persisted = try await reopened.snapshot()
        XCTAssertEqual(persisted, settings)
        let arguments = persisted.runtimeArguments
        XCTAssertTrue(arguments.contains("host_name=Studio Host"))
        XCTAssertTrue(arguments.contains("device_enrollment_enabled=false"))
        XCTAssertTrue(arguments.contains("workspace_policy=promote-virtual-main"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("enable_pairing=") })
        XCTAssertTrue(arguments.contains("upnp=true"))
        XCTAssertTrue(arguments.contains("origin_admin_allowed=wan"))
        XCTAssertTrue(arguments.contains("fec_percentage=30"))
        let prepArgument = try XCTUnwrap(arguments.first { $0.hasPrefix("global_prep_cmd=") })
        XCTAssertTrue(prepArgument.contains("\"run\":\"prepare\""))
        XCTAssertTrue(prepArgument.contains("\"undo\":\"restore\""))
        XCTAssertTrue(prepArgument.contains("\"privilege\":\"user\""))
        let serverArgument = try XCTUnwrap(arguments.first { $0.hasPrefix("server_cmd=") })
        XCTAssertTrue(serverArgument.contains("\"name\":\"Wake\""))
        XCTAssertTrue(serverArgument.contains("\"command\":\"wake-host\""))
        XCTAssertTrue(serverArgument.contains("\"privilege\":\"user\""))
    }

    func testRetiredEmptySelectorsDoNotDiscardValidHostSettings() async throws {
        let suiteName = "LumenHostSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("", forKey: "stream.adapter-selector")
        defaults.set("", forKey: "stream.output-selector")
        defaults.set("", forKey: "audio.sink")
        defaults.set(48_989, forKey: "network.port")
        defaults.set(true, forKey: "network.upnp")

        let store = try LumenHostSettingsStore(suiteName: suiteName)
        let settings = try await store.snapshot()

        XCTAssertEqual(settings.adapterSelector, "automatic")
        XCTAssertEqual(settings.outputSelector, "automatic")
        XCTAssertEqual(settings.audioSink, "system-default")
        XCTAssertEqual(settings.port, 48_989)
        XCTAssertTrue(settings.upnpEnabled)
    }

    func testInvalidHostValuesAreRejected() async throws {
        let suiteName = "LumenHostSettingsStoreTests.\(UUID().uuidString)"
        let store = try LumenHostSettingsStore(suiteName: suiteName)
        var settings = try await store.snapshot()
        settings.name = "  "

        do {
            try await store.save(settings)
            XCTFail("Expected invalid settings to be rejected")
        } catch {
            XCTAssertEqual(error as? LumenHostSettingsError, .invalidValue)
        }
    }

    func testRuntimeArgumentsOmitUnsetOptionalValues() {
        let settings = LumenNativeHostSettings.defaults
        let arguments = settings.runtimeArguments

        XCTAssertFalse(arguments.contains { $0.hasPrefix("adapter_name=") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("output_name=") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("audio_sink=") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("external_ip=") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("locale=") })
        XCTAssertTrue(settings.privateKeyPath.hasSuffix("/credentials/cakey.pem"))
        XCTAssertTrue(settings.certificatePath.hasSuffix("/credentials/cacert.pem"))
        XCTAssertEqual(settings.credentialsFilePath, settings.stateFilePath)
    }
}
