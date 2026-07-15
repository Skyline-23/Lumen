import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

public struct LumenVideoToolboxProbeEnvironment: Hashable, Codable, Sendable {
    public let osBuild: String
    public let hardwareIdentity: String

    public init(osBuild: String, hardwareIdentity: String) {
        self.osBuild = osBuild
        self.hardwareIdentity = hardwareIdentity
    }

    public static var current: Self {
        Self(
            osBuild: sysctlString("kern.osversion") ?? "unknown-os-build",
            hardwareIdentity: [
                sysctlString("hw.model"),
                sysctlString("hw.targettype")
            ]
            .compactMap { $0 }
            .joined(separator: "|")
            .nonEmpty ?? "unknown-hardware"
        )
    }
}

public enum LumenVideoToolboxProbeTarget: String, CaseIterable, Codable, Sendable {
    case h264High444Predictive
    case hevcMain444
    case hevcMain44410

    fileprivate var codec: String {
        switch self {
        case .h264High444Predictive: "h264"
        case .hevcMain444, .hevcMain44410: "hevc"
        }
    }

    fileprivate var codecType: CMVideoCodecType {
        switch self {
        case .h264High444Predictive: kCMVideoCodecType_H264
        case .hevcMain444, .hevcMain44410: kCMVideoCodecType_HEVC
        }
    }

    fileprivate var profileFragment: String {
        switch self {
        case .h264High444Predictive: "High444Predictive"
        case .hevcMain444: "Main444_"
        case .hevcMain44410: "Main44410"
        }
    }

    fileprivate var pixelFormat: OSType {
        switch self {
        case .h264High444Predictive, .hevcMain444:
            kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        case .hevcMain44410:
            kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        }
    }

    fileprivate var inputFourCC: String {
        fourCCString(pixelFormat)
    }
}

public struct LumenVideoToolboxProbeStatuses: Equatable, Sendable {
    public let discoveryStatus: Int32?
    public let createStatus: Int32?
    public let setStatus: Int32?
    public let prepareStatus: Int32?
    public let encodeStatus: Int32?
    public let callbackStatus: Int32?

    public init(
        discoveryStatus: Int32?,
        createStatus: Int32?,
        setStatus: Int32?,
        prepareStatus: Int32?,
        encodeStatus: Int32?,
        callbackStatus: Int32?
    ) {
        self.discoveryStatus = discoveryStatus
        self.createStatus = createStatus
        self.setStatus = setStatus
        self.prepareStatus = prepareStatus
        self.encodeStatus = encodeStatus
        self.callbackStatus = callbackStatus
    }

    public static let allSuccessful = Self(
        discoveryStatus: noErr,
        createStatus: noErr,
        setStatus: noErr,
        prepareStatus: noErr,
        encodeStatus: noErr,
        callbackStatus: noErr
    )
}

public enum LumenVideoToolboxParsedConfiguration: Equatable, Sendable {
    case h264(profileIdc: Int)
    case hevc(chromaFormatIdc: Int, lumaBitDepth: Int, chromaBitDepth: Int)

    fileprivate var profileIdc: Int? {
        guard case let .h264(profileIdc) = self else { return nil }
        return profileIdc
    }

    fileprivate var chromaFormatIdc: Int? {
        guard case let .hevc(chromaFormatIdc, _, _) = self else { return nil }
        return chromaFormatIdc
    }

    fileprivate var lumaBitDepth: Int? {
        guard case let .hevc(_, lumaBitDepth, _) = self else { return nil }
        return lumaBitDepth
    }

    fileprivate var chromaBitDepth: Int? {
        guard case let .hevc(_, _, chromaBitDepth) = self else { return nil }
        return chromaBitDepth
    }
}

public struct LumenVideoToolboxProbeAssessment: Equatable, Sendable {
    public let advertised: Bool
    public let rejectionReason: String?

    public init(advertised: Bool, rejectionReason: String?) {
        self.advertised = advertised
        self.rejectionReason = rejectionReason
    }
}

public struct LumenVideoToolboxCapabilityProbeRow: Encodable, Equatable, Sendable {
    public let codec: String
    public let requestedProfileFamily: String
    public let profile: String?
    public let inputFourCC: String
    public let discoveryStatus: Int32?
    public let createStatus: Int32?
    public let setStatus: Int32?
    public let prepareStatus: Int32?
    public let encodeStatus: Int32?
    public let callbackStatus: Int32?
    public let hardwareUsed: Bool?
    public let profileIdc: Int?
    public let chromaFormatIdc: Int?
    public let lumaBitDepth: Int?
    public let chromaBitDepth: Int?
    public let osBuild: String
    public let hardwareIdentity: String
    public let advertised: Bool
    public let rejectionReason: String?

    fileprivate init(
        target: LumenVideoToolboxProbeTarget,
        profile: String?,
        statuses: LumenVideoToolboxProbeStatuses,
        hardwareUsed: Bool?,
        parsedConfiguration: LumenVideoToolboxParsedConfiguration?,
        environment: LumenVideoToolboxProbeEnvironment,
        assessment: LumenVideoToolboxProbeAssessment
    ) {
        codec = target.codec
        requestedProfileFamily = target.rawValue
        self.profile = profile
        inputFourCC = target.inputFourCC
        discoveryStatus = statuses.discoveryStatus
        createStatus = statuses.createStatus
        setStatus = statuses.setStatus
        prepareStatus = statuses.prepareStatus
        encodeStatus = statuses.encodeStatus
        callbackStatus = statuses.callbackStatus
        self.hardwareUsed = hardwareUsed
        profileIdc = parsedConfiguration?.profileIdc
        chromaFormatIdc = parsedConfiguration?.chromaFormatIdc
        lumaBitDepth = parsedConfiguration?.lumaBitDepth
        chromaBitDepth = parsedConfiguration?.chromaBitDepth
        osBuild = environment.osBuild
        hardwareIdentity = environment.hardwareIdentity
        advertised = assessment.advertised
        rejectionReason = assessment.rejectionReason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(codec, forKey: .codec)
        try container.encode(requestedProfileFamily, forKey: .requestedProfileFamily)
        try container.encodeIfPresent(profile, forKey: .profile)
        if profile == nil { try container.encodeNil(forKey: .profile) }
        try container.encode(inputFourCC, forKey: .inputFourCC)
        try container.encodeOptional(discoveryStatus, forKey: .discoveryStatus)
        try container.encodeOptional(createStatus, forKey: .createStatus)
        try container.encodeOptional(setStatus, forKey: .setStatus)
        try container.encodeOptional(prepareStatus, forKey: .prepareStatus)
        try container.encodeOptional(encodeStatus, forKey: .encodeStatus)
        try container.encodeOptional(callbackStatus, forKey: .callbackStatus)
        try container.encodeOptional(hardwareUsed, forKey: .hardwareUsed)
        try container.encodeOptional(profileIdc, forKey: .profileIdc)
        try container.encodeOptional(chromaFormatIdc, forKey: .chromaFormatIdc)
        try container.encodeOptional(lumaBitDepth, forKey: .lumaBitDepth)
        try container.encodeOptional(chromaBitDepth, forKey: .chromaBitDepth)
        try container.encode(osBuild, forKey: .osBuild)
        try container.encode(hardwareIdentity, forKey: .hardwareIdentity)
        try container.encode(advertised, forKey: .advertised)
        try container.encodeIfPresent(rejectionReason, forKey: .rejectionReason)
        if rejectionReason == nil { try container.encodeNil(forKey: .rejectionReason) }
    }

    private enum CodingKeys: String, CodingKey {
        case codec
        case requestedProfileFamily
        case profile
        case inputFourCC
        case discoveryStatus
        case createStatus
        case setStatus
        case prepareStatus
        case encodeStatus
        case callbackStatus
        case hardwareUsed
        case profileIdc
        case chromaFormatIdc
        case lumaBitDepth
        case chromaBitDepth
        case osBuild
        case hardwareIdentity
        case advertised
        case rejectionReason
    }
}

public enum LumenVideoToolboxCodecConfigurationParser {
    public struct AVCConfiguration: Equatable, Sendable {
        public let profileIdc: Int
    }

    public struct HEVCConfiguration: Equatable, Sendable {
        public let chromaFormatIdc: Int
        public let lumaBitDepth: Int
        public let chromaBitDepth: Int
    }

    public static func parseAVCC(_ data: Data) -> AVCConfiguration? {
        guard data.count >= 4, data[0] == 1 else { return nil }
        return AVCConfiguration(profileIdc: Int(data[1]))
    }

    public static func parseHVCC(_ data: Data) -> HEVCConfiguration? {
        guard data.count >= 23,
              data[0] == 1,
              data[16] & 0xFC == 0xFC,
              data[17] & 0xF8 == 0xF8,
              data[18] & 0xF8 == 0xF8 else {
            return nil
        }
        return HEVCConfiguration(
            chromaFormatIdc: Int(data[16] & 0x03),
            lumaBitDepth: Int(data[17] & 0x07) + 8,
            chromaBitDepth: Int(data[18] & 0x07) + 8
        )
    }
}

public actor LumenVideoToolboxCapabilityProbeCache {
    private var cachedRows: [LumenVideoToolboxProbeEnvironment: [LumenVideoToolboxCapabilityProbeRow]] = [:]

    public init() {}

    public func rows(
        for environment: LumenVideoToolboxProbeEnvironment,
        loader: @Sendable () async throws -> [LumenVideoToolboxCapabilityProbeRow]
    ) async rethrows -> [LumenVideoToolboxCapabilityProbeRow] {
        if let cached = cachedRows[environment] {
            return cached
        }
        let loaded = try await loader()
        if loaded.allSatisfy(\.isStableCacheResult) {
            cachedRows[environment] = loaded
        }
        return loaded
    }
}

private extension LumenVideoToolboxCapabilityProbeRow {
    var isStableCacheResult: Bool {
        advertised || rejectionReason == "required-profile-not-supported"
    }
}

public enum LumenVideoToolboxCapabilityProbe {
    public static let cache = LumenVideoToolboxCapabilityProbeCache()

    public static func discoveredProfile(
        containing fragment: String,
        supportedProfiles: [String]
    ) -> String? {
        supportedProfiles
            .filter { $0.contains(fragment) }
            .sorted()
            .first
    }

    public static func assess(
        target: LumenVideoToolboxProbeTarget,
        statuses: LumenVideoToolboxProbeStatuses,
        hardwareUsed: Bool?,
        parsedConfiguration: LumenVideoToolboxParsedConfiguration?
    ) -> LumenVideoToolboxProbeAssessment {
        let statusChecks: [(Int32?, String)] = [
            (statuses.discoveryStatus, "supported-property-discovery-failed"),
            (statuses.createStatus, "compression-session-create-failed"),
            (statuses.setStatus, "compression-session-property-set-failed"),
            (statuses.prepareStatus, "compression-session-prepare-failed"),
            (statuses.encodeStatus, "compression-session-encode-failed"),
            (statuses.callbackStatus, "compression-output-callback-failed")
        ]
        if let failure = statusChecks.first(where: { $0.0 != noErr }) {
            return .init(advertised: false, rejectionReason: failure.1)
        }
        guard hardwareUsed == true else {
            return .init(advertised: false, rejectionReason: "hardware-encoder-not-used")
        }
        guard let parsedConfiguration else {
            return .init(advertised: false, rejectionReason: "malformed-codec-configuration")
        }

        let matches: Bool
        switch (target, parsedConfiguration) {
        case let (.h264High444Predictive, .h264(profileIdc)):
            matches = profileIdc == 244
        case let (.hevcMain444, .hevc(chromaFormatIdc, lumaBitDepth, chromaBitDepth)):
            matches = chromaFormatIdc == 3 && lumaBitDepth == 8 && chromaBitDepth == 8
        case let (.hevcMain44410, .hevc(chromaFormatIdc, lumaBitDepth, chromaBitDepth)):
            matches = chromaFormatIdc == 3 && lumaBitDepth == 10 && chromaBitDepth == 10
        default:
            matches = false
        }
        return matches
            ? .init(advertised: true, rejectionReason: nil)
            : .init(advertised: false, rejectionReason: "codec-configuration-contract-mismatch")
    }

    public static func auditRequiredHardware444(
        environment: LumenVideoToolboxProbeEnvironment = .current,
        timeout: TimeInterval = 5
    ) async -> [LumenVideoToolboxCapabilityProbeRow] {
        var rows: [LumenVideoToolboxCapabilityProbeRow] = []
        for target in LumenVideoToolboxProbeTarget.allCases {
            let discovery = supportedProfiles(for: target.codecType)
            guard let profile = discoveredProfile(
                containing: target.profileFragment,
                supportedProfiles: discovery.profiles
            ) else {
                let statuses = LumenVideoToolboxProbeStatuses(
                    discoveryStatus: discovery.status,
                    createStatus: nil,
                    setStatus: nil,
                    prepareStatus: nil,
                    encodeStatus: nil,
                    callbackStatus: nil
                )
                rows.append(
                    .init(
                        target: target,
                        profile: nil,
                        statuses: statuses,
                        hardwareUsed: nil,
                        parsedConfiguration: nil,
                        environment: environment,
                        assessment: .init(
                            advertised: false,
                            rejectionReason: discovery.status == noErr
                                ? "required-profile-not-supported"
                                : "supported-property-discovery-failed"
                        )
                    )
                )
                continue
            }

            let attempt = LumenVideoToolboxProbeAttempt(
                target: target,
                profile: profile,
                discoveryStatus: discovery.status,
                environment: environment
            )
            rows.append(await attempt.run(timeout: timeout))
        }
        return rows
    }

    public static func cachedRequiredHardware444(
        environment: LumenVideoToolboxProbeEnvironment = .current,
        timeout: TimeInterval = 5
    ) async -> [LumenVideoToolboxCapabilityProbeRow] {
        await cache.rows(for: environment) {
            await auditRequiredHardware444(environment: environment, timeout: timeout)
        }
    }

    public static func advertisedRequiredHardware444(
        environment: LumenVideoToolboxProbeEnvironment = .current,
        timeout: TimeInterval = 5
    ) async -> [LumenVideoToolboxCapabilityProbeRow] {
        await cachedRequiredHardware444(environment: environment, timeout: timeout)
            .filter(\.advertised)
    }

    public static func writeArtifact(
        _ rows: [LumenVideoToolboxCapabilityProbeRow],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(rows).write(to: url, options: .atomic)
    }

    private static func supportedProfiles(
        for codecType: CMVideoCodecType
    ) -> (status: OSStatus, profiles: [String]) {
        var encoderID: CFString?
        var supportedProperties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 192,
            height: 108,
            codecType: codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &supportedProperties
        )
        guard status == noErr,
              encoderID != nil,
              let properties = supportedProperties as? [CFString: Any],
              let profile = properties[kVTCompressionPropertyKey_ProfileLevel] as? [CFString: Any],
              let values = profile[kVTPropertySupportedValueListKey] as? [String] else {
            return (status, [])
        }
        return (status, values)
    }
}

private final class LumenVideoToolboxProbeCallbackBox: @unchecked Sendable {
    let callback: @Sendable (OSStatus, Data?) -> Void

    init(callback: @escaping @Sendable (OSStatus, Data?) -> Void) {
        self.callback = callback
    }
}

private let lumenVideoToolboxProbeOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    _,
    sampleBuffer in
    guard let outputCallbackRefCon else { return }
    let callback = Unmanaged<LumenVideoToolboxProbeCallbackBox>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    let configurationData = sampleBuffer.flatMap(codecConfigurationData)
    callback.callback(status, configurationData)
}

private actor LumenVideoToolboxProbeCompletion {
    private var result: LumenVideoToolboxCapabilityProbeRow?
    private var waiter: CheckedContinuation<LumenVideoToolboxCapabilityProbeRow, Never>?

    func wait() async -> LumenVideoToolboxCapabilityProbeRow {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ row: LumenVideoToolboxCapabilityProbeRow) {
        guard result == nil else { return }
        result = row
        waiter?.resume(returning: row)
        waiter = nil
    }
}

private final class LumenVideoToolboxProbeAttempt: @unchecked Sendable {
    private let target: LumenVideoToolboxProbeTarget
    private let profile: String
    private let discoveryStatus: OSStatus
    private let environment: LumenVideoToolboxProbeEnvironment
    private let queue: DispatchQueue
    private let completion = LumenVideoToolboxProbeCompletion()

    // All mutable attempt state below is isolated to `queue`. VideoToolbox's C
    // callback copies configuration data, then re-enters that queue.
    private var createStatus: OSStatus?
    private var setStatus: OSStatus?
    private var prepareStatus: OSStatus?
    private var encodeStatus: OSStatus?
    private var hardwareUsed: Bool?
    private var callbackBox: LumenVideoToolboxProbeCallbackBox?

    init(
        target: LumenVideoToolboxProbeTarget,
        profile: String,
        discoveryStatus: OSStatus,
        environment: LumenVideoToolboxProbeEnvironment
    ) {
        self.target = target
        self.profile = profile
        self.discoveryStatus = discoveryStatus
        self.environment = environment
        queue = DispatchQueue(label: "dev.skyline23.lumen.vt-capability.\(target.rawValue)")
    }

    func run(timeout: TimeInterval) async -> LumenVideoToolboxCapabilityProbeRow {
        queue.async { self.performEncode() }
        let timeoutTask = Task {
            let safeTimeout = timeout.isFinite ? max(timeout, 0.1) : 5
            let nanoseconds = UInt64(safeTimeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await completion.resolve(timeoutRow())
        }
        let row = await completion.wait()
        timeoutTask.cancel()
        return row
    }

    private func performEncode() {
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: 192,
            kCVPixelBufferHeightKey: 108,
            kCVPixelBufferPixelFormatTypeKey: target.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        callbackBox = LumenVideoToolboxProbeCallbackBox { [weak self] status, configurationData in
            guard let self else { return }
            queue.async {
                self.finish(callbackStatus: status, configurationData: configurationData)
            }
        }

        var session: VTCompressionSession?
        createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 192,
            height: 108,
            codecType: target.codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: lumenVideoToolboxProbeOutputCallback,
            refcon: callbackBox.map { Unmanaged.passUnretained($0).toOpaque() },
            compressionSessionOut: &session
        )
        guard createStatus == noErr, let session else {
            finish(callbackStatus: nil, configurationData: nil)
            return
        }
        defer { VTCompressionSessionInvalidate(session) }

        setStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: profile as CFString
        )
        guard setStatus == noErr else {
            finish(callbackStatus: nil, configurationData: nil)
            return
        }
        prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            finish(callbackStatus: nil, configurationData: nil)
            return
        }

        var hardwareValue: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &hardwareValue) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        if hardwareStatus == noErr {
            hardwareUsed = hardwareValue as? Bool
        }

        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            192,
            108,
            target.pixelFormat,
            imageAttributes as CFDictionary,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            encodeStatus = pixelStatus
            finish(callbackStatus: nil, configurationData: nil)
            return
        }
        initialize(pixelBuffer, for: target.pixelFormat)

        var infoFlags: VTEncodeInfoFlags = []
        encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard encodeStatus == noErr else {
            finish(callbackStatus: nil, configurationData: nil)
            return
        }
        let completionStatus = VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )
        if completionStatus != noErr {
            encodeStatus = completionStatus
            finish(callbackStatus: nil, configurationData: nil)
        }
    }

    private func finish(callbackStatus: OSStatus?, configurationData: Data?) {
        let statuses = LumenVideoToolboxProbeStatuses(
            discoveryStatus: discoveryStatus,
            createStatus: createStatus,
            setStatus: setStatus,
            prepareStatus: prepareStatus,
            encodeStatus: encodeStatus,
            callbackStatus: callbackStatus
        )
        let parsedConfiguration: LumenVideoToolboxParsedConfiguration?
        switch target {
        case .h264High444Predictive:
            parsedConfiguration = configurationData
                .flatMap(LumenVideoToolboxCodecConfigurationParser.parseAVCC)
                .map { .h264(profileIdc: $0.profileIdc) }
        case .hevcMain444, .hevcMain44410:
            parsedConfiguration = configurationData
                .flatMap(LumenVideoToolboxCodecConfigurationParser.parseHVCC)
                .map {
                    .hevc(
                        chromaFormatIdc: $0.chromaFormatIdc,
                        lumaBitDepth: $0.lumaBitDepth,
                        chromaBitDepth: $0.chromaBitDepth
                    )
                }
        }
        let assessment = LumenVideoToolboxCapabilityProbe.assess(
            target: target,
            statuses: statuses,
            hardwareUsed: hardwareUsed,
            parsedConfiguration: parsedConfiguration
        )
        let row = LumenVideoToolboxCapabilityProbeRow(
            target: target,
            profile: profile,
            statuses: statuses,
            hardwareUsed: hardwareUsed,
            parsedConfiguration: parsedConfiguration,
            environment: environment,
            assessment: assessment
        )
        callbackBox = nil
        Task { await completion.resolve(row) }
    }

    private func timeoutRow() -> LumenVideoToolboxCapabilityProbeRow {
        .init(
            target: target,
            profile: profile,
            statuses: .init(
                discoveryStatus: discoveryStatus,
                createStatus: nil,
                setStatus: nil,
                prepareStatus: nil,
                encodeStatus: nil,
                callbackStatus: nil
            ),
            hardwareUsed: nil,
            parsedConfiguration: nil,
            environment: environment,
            assessment: .init(advertised: false, rejectionReason: "probe-timeout")
        )
    }
}

private func codecConfigurationData(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any],
          let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
            as? [String: Any] else {
        return nil
    }
    return (atoms["avcC"] as? Data) ?? (atoms["hvcC"] as? Data)
}

private func initialize(_ pixelBuffer: CVPixelBuffer, for pixelFormat: OSType) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard CVPixelBufferIsPlanar(pixelBuffer) else { return }
    for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
        let byteCount = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        if plane == 1, pixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange {
            memset(baseAddress, 128, byteCount)
        } else if plane == 1, pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange {
            let sampleCount = byteCount / MemoryLayout<UInt16>.size
            baseAddress.bindMemory(to: UInt16.self, capacity: sampleCount)
                .update(repeating: UInt16(512 << 6), count: sampleCount)
        } else {
            memset(baseAddress, 0, byteCount)
        }
    }
}

private func fourCCString(_ value: OSType) -> String {
    String(bytes: [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ], encoding: .ascii) ?? String(value)
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
