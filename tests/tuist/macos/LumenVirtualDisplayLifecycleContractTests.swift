import Foundation
import Testing

@Suite("Virtual display lifecycle contract")
struct LumenVirtualDisplayLifecycleContractTests {
    @Test("Virtual display promotion removes mirroring before layout mutation")
    func promotionUnmirrorsBeforeRepositioning() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/LumenMacDisplayWorkspace.swift"
        )
        let start = try #require(
            source.range(of: "    public func promoteVirtualDisplay(")
        )
        let tail = source[start.lowerBound...]
        let end = try #require(
            tail.range(of: "\n    public func moveTargetWindows")
        )
        let promotion = tail[..<end.lowerBound]

        let unmirror = try #require(
            promotion.range(of: "CGConfigureDisplayMirrorOfDisplay")
        )
        let origin = try #require(promotion.range(of: "CGConfigureDisplayOrigin"))
        #expect(unmirror.lowerBound < origin.lowerBound)
        #expect(promotion.contains("kCGNullDirectDisplay"))
    }

    @Test("Virtual display settings declare rotation and HDR reference state")
    func settingsMatchDesktopDisplayContract() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/LumenNativeVirtualDisplay.m"
        )

        #expect(source.contains("[_settings setValue:@0 forKey:@\"rotation\"]"))
        #expect(
            source.contains(
                "[_settings setValue:@(configuration.hdrEnabled) forKey:@\"isReference\"]"
            )
        )
        #expect(source.contains("kCDDisplayPresetMaxHDRLuminanceKey"))
        #expect(source.contains("setDisplayInfo(descriptor, setterSelector, value, key)"))
        #expect(!source.contains("displayInfo[key] != nil"))
    }

    @Test("CG virtual display publishes the logical and native HiDPI mode pair")
    func cgVirtualDisplayPublishesHiDPIModePair() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/LumenNativeVirtualDisplay.m"
        )

        #expect(source.contains("NSArray *publishedModes = @[initialMode, backingMode];"))
        #expect(source.contains("? @[candidateMode, candidateBackingMode]"))
        #expect(
            source.contains(
                "[_settings setValue:@(configuration.highDensity) forKey:@\"hiDPI\"]"
            )
        )
    }

    @Test("HiDPI reconfiguration explicitly reselects the native backing mode")
    func hidpiReconfigurationReselectsPublishedMode() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/" +
                "LumenVirtualDisplayOwner.swift"
        )
        let start = try #require(source.range(of: "    func configure("))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: "\n    func reconfigure("))
        let configure = tail[..<end.lowerBound]
        let update = try #require(
            configure.range(of: "try display.updateLogicalWidth(")
        )
        let select = try #require(
            configure.range(of: "try await selectPublishedHiDPIMode(display)")
        )

        #expect(update.lowerBound < select.lowerBound)
        #expect(configure.contains("display.backingWidth != display.logicalWidth"))
    }

    @Test("Private virtual display lifecycle keeps callbacks off the worker main queue")
    func privateLifecycleUsesResponsivePublicationContext() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/LumenNativeVirtualDisplay.m"
        )

        #expect(
            source.components(
                separatedBy: "if (![NSThread isMainThread])"
            ).count - 1 >= 3
        )
        #expect(
            source.contains(
                "_callbackQueue = dispatch_get_global_queue(" +
                    "QOS_CLASS_USER_INITIATED, 0);"
            )
        )
        #expect(
            source.contains("setQueue:")
        )
        #expect(
            source.contains("setDispatchQueue:")
        )
    }

    @Test("Virtual display descriptor assigns both observed serial selectors")
    func descriptorAssignsReferenceSerialSelectors() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/LumenNativeVirtualDisplay.m"
        )

        #expect(source.contains("setSerialNumber:"))
        #expect(source.contains("setSerialNum:"))
    }

    @Test("ScreenCaptureKit enumeration uses the serialized completion API")
    func screenCaptureEnumerationUsesCompletionBoundary() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/" +
                "LumenScreenCaptureDisplayAdmission.swift"
        )

        #expect(
            source.contains(
                "getShareableContentExcludingDesktopWindows"
            )
        )
        #expect(!source.contains("SCShareableContent.current"))
    }

    @Test("Worker warms ScreenCaptureKit after AppKit readiness without delaying QUIC startup")
    func workerWarmsScreenCaptureInventoryAsynchronously() throws {
        let warmup = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/" +
                "LumenScreenCaptureInventoryWarmup.swift"
        )
        let entry = try source("engine/lumen-host/src/entry.rs")
        let workerStart = try #require(
            entry.range(of: "worker_platform.warm_screen_capture_inventory();")
        )
        let runtimeStart = try #require(
            entry.range(
                of: "HostRuntime::new(NativeHostService::production_with_platform"
            )
        )

        #expect(warmup.contains("Task(priority: .utility)"))
        #expect(
            warmup.contains("try await SCShareableContent.excludingDesktopWindows")
        )
        #expect(workerStart.lowerBound < runtimeStart.lowerBound)
    }

    @Test("Prepared exact display is consumed without post-mirror publication revalidation")
    func preparedDisplaySurvivesMirrorTopologyCommit() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/" +
                "LumenScreenCaptureDisplayPrefetch.swift"
        )
        let start = try #require(
            source.range(of: "    private static func takeValidatedPrefetch(")
        )
        let tail = source[start.lowerBound...]
        let end = try #require(
            tail.range(of: "\n    private static func prefetchExpiration")
        )
        let admission = tail[..<end.lowerBound]

        #expect(admission.contains("expectedOwners.owner"))
        #expect(admission.contains("isCurrent(displayID: displayID)"))
        #expect(!admission.contains("DisplayReadiness.snapshot"))
        #expect(!admission.contains("isPreparedHandleReady"))
    }

    @Test("Desktop mirror topology uses Core Graphics completion callbacks")
    func desktopMirrorUsesReconfigurationCallbacks() throws {
        let observer = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/" +
                "LumenDisplayReconfigurationObserver.swift"
        )
        let preparation = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/" +
                "LumenWorkspaceSession+Preparation.swift"
        )
        let start = try #require(
            preparation.range(of: "    private func prepareDesktopMirrorCapture()")
        )
        let tail = preparation[start.lowerBound...]
        let end = try #require(
            tail.range(of: "\n    private func executePreparationCommand")
        )
        let desktopMirrorPreparation = tail[..<end.lowerBound]

        #expect(observer.contains("CGDisplayRegisterReconfigurationCallback"))
        #expect(observer.contains("CGDisplayRemoveReconfigurationCallback"))
        #expect(observer.contains("beginConfigurationFlag"))
        #expect(!desktopMirrorPreparation.contains("settleOwnedVirtualDisplayMode"))
        #expect(!desktopMirrorPreparation.contains("stabilizeOwnedVirtualDisplay"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = try repositoryRoot()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath)
        while candidate.path != "/" {
            candidate.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Cargo.toml").path
            ) {
                return candidate
            }
        }
        throw VirtualDisplayLifecycleContractError.repositoryRootNotFound
    }
}

private enum VirtualDisplayLifecycleContractError: Error {
    case repositoryRootNotFound
}
