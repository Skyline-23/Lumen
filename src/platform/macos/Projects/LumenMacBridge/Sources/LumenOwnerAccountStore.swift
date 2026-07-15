import Foundation
import LumenEngineBridge

public enum LumenOwnerAccountState: Equatable, Sendable {
    case uninitialized
    case ready
    case corrupt
    case unavailable
}

public enum LumenOwnerAccountError: Error, Equatable, LocalizedError, Sendable {
    case incompatibleABI(expected: UInt32, actual: UInt32)
    case allocationFailed
    case invalidInput
    case alreadyExists
    case deviceAlreadyEnrolled
    case authenticationFailed
    case storageUnavailable
    case corruptData
    case engineStatus(UInt32)

    public var errorDescription: String? {
        switch self {
        case let .incompatibleABI(expected, actual):
            "Lumen engine ABI mismatch (expected \(expected), received \(actual))."
        case .allocationFailed:
            "The owner account store could not be opened."
        case .invalidInput:
            "Use a non-empty owner name and a password with at least 12 characters."
        case .alreadyExists:
            "An owner account already exists."
        case .deviceAlreadyEnrolled:
            "A device with this public key is already enrolled."
        case .authenticationFailed:
            "The owner name or password is incorrect."
        case .storageUnavailable:
            "The owner account could not be read or saved."
        case .corruptData:
            "The owner account data is damaged. Factory reset is required."
        case let .engineStatus(status):
            "The Lumen engine returned status \(status)."
        }
    }
}

public struct LumenDeviceEnrollment: Equatable, Sendable {
    public let deviceID: String
    public let refreshToken: String

    public init(deviceID: String, refreshToken: String) {
        self.deviceID = deviceID
        self.refreshToken = refreshToken
    }
}

public actor LumenOwnerAccountStore {
    public static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen", isDirectory: true)
            .appendingPathComponent("owner-account.json", isDirectory: false)
    }

    private let ownerHandle: LumenEngineHandle
    private let deviceHandle: LumenEngineHandle

    public init(
        fileURL: URL = LumenOwnerAccountStore.defaultFileURL,
        deviceFileURL: URL? = nil
    ) throws {
        let actualVersion = LumenEngineBridgeABIVersion()
        guard actualVersion == LUMEN_ENGINE_ABI_VERSION else {
            throw LumenOwnerAccountError.incompatibleABI(
                expected: LUMEN_ENGINE_ABI_VERSION,
                actual: actualVersion
            )
        }

        var openedHandle: OpaquePointer?
        let status = fileURL.path.withCString { filePath in
            lumen_owner_store_open(filePath, &openedHandle)
        }
        try Self.requireSuccess(status)
        guard let openedHandle else {
            throw LumenOwnerAccountError.allocationFailed
        }
        let resolvedDeviceFileURL = deviceFileURL ?? fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("devices.json", isDirectory: false)
        var openedDeviceHandle: OpaquePointer?
        let deviceStatus = resolvedDeviceFileURL.path.withCString { filePath in
            lumen_device_store_open(filePath, &openedDeviceHandle)
        }
        do {
            try Self.requireSuccess(deviceStatus)
        } catch {
            lumen_owner_store_destroy(openedHandle)
            throw error
        }
        guard let openedDeviceHandle else {
            lumen_owner_store_destroy(openedHandle)
            throw LumenOwnerAccountError.allocationFailed
        }
        ownerHandle = LumenEngineHandle(openedHandle, destructor: lumen_owner_store_destroy)
        deviceHandle = LumenEngineHandle(openedDeviceHandle, destructor: lumen_device_store_destroy)
    }

    public func state() -> LumenOwnerAccountState {
        switch lumen_owner_store_state(ownerHandle.rawValue) {
        case LumenOwnerStateUninitialized:
            .uninitialized
        case LumenOwnerStateReady:
            .ready
        case LumenOwnerStateCorrupt:
            .corrupt
        default:
            .unavailable
        }
    }

    public func createOwner(username: String, password: String) throws {
        let status = username.withCString { usernamePointer in
            password.withCString { passwordPointer in
                lumen_owner_store_create_owner(ownerHandle.rawValue, usernamePointer, passwordPointer)
            }
        }
        try Self.requireSuccess(status)
    }

    public func verifyOwner(username: String, password: String) throws {
        let status = username.withCString { usernamePointer in
            password.withCString { passwordPointer in
                lumen_owner_store_verify_owner(ownerHandle.rawValue, usernamePointer, passwordPointer)
            }
        }
        try Self.requireSuccess(status)
    }

    public func username() throws -> String {
        var buffer = Array<CChar>(repeating: 0, count: 256)
        let status = buffer.withUnsafeMutableBufferPointer { buffer in
            lumen_owner_store_copy_username(ownerHandle.rawValue, buffer.baseAddress, buffer.count)
        }
        try Self.requireSuccess(status)
        return lumenStringFromCString(buffer)
    }

    public func enrollDevice(
        ownerPassword: String,
        name: String,
        platform: String,
        publicKey: String
    ) throws -> LumenDeviceEnrollment {
        let ownerUsername = try username()
        var deviceIDBuffer = Array<CChar>(repeating: 0, count: 64)
        var refreshTokenBuffer = Array<CChar>(repeating: 0, count: 128)
        let status = ownerUsername.withCString { ownerUsernamePointer in
            ownerPassword.withCString { ownerPasswordPointer in
                name.withCString { namePointer in
                    platform.withCString { platformPointer in
                        publicKey.withCString { publicKeyPointer in
                            deviceIDBuffer.withUnsafeMutableBufferPointer { deviceIDBuffer in
                                refreshTokenBuffer.withUnsafeMutableBufferPointer { refreshTokenBuffer in
                                    lumen_device_store_enroll(
                                        deviceHandle.rawValue,
                                        ownerHandle.rawValue,
                                        ownerUsernamePointer,
                                        ownerPasswordPointer,
                                        namePointer,
                                        platformPointer,
                                        publicKeyPointer,
                                        deviceIDBuffer.baseAddress,
                                        deviceIDBuffer.count,
                                        refreshTokenBuffer.baseAddress,
                                        refreshTokenBuffer.count
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        try Self.requireSuccess(status, duplicateError: .deviceAlreadyEnrolled)
        return LumenDeviceEnrollment(
            deviceID: lumenStringFromCString(deviceIDBuffer),
            refreshToken: lumenStringFromCString(refreshTokenBuffer)
        )
    }

    public func verifyRefreshToken(deviceID: String, refreshToken: String) throws {
        let status = deviceID.withCString { deviceIDPointer in
            refreshToken.withCString { refreshTokenPointer in
                lumen_device_store_verify_refresh_token(
                    deviceHandle.rawValue,
                    deviceIDPointer,
                    refreshTokenPointer
                )
            }
        }
        try Self.requireSuccess(status)
    }

    public func revokeDevice(deviceID: String, ownerPassword: String) throws {
        let ownerUsername = try username()
        let status = ownerUsername.withCString { ownerUsernamePointer in
            ownerPassword.withCString { ownerPasswordPointer in
                deviceID.withCString { deviceIDPointer in
                    lumen_device_store_revoke(
                        deviceHandle.rawValue,
                        ownerHandle.rawValue,
                        ownerUsernamePointer,
                        ownerPasswordPointer,
                        deviceIDPointer
                    )
                }
            }
        }
        try Self.requireSuccess(status)
    }

    public func activeDeviceCount() -> UInt32 {
        lumen_device_store_active_count(deviceHandle.rawValue)
    }

    private static func requireSuccess(
        _ status: LumenEngineStatus,
        duplicateError: LumenOwnerAccountError = .alreadyExists
    ) throws {
        switch status {
        case LumenEngineStatusOk:
            return
        case LumenEngineStatusInvalidArgument:
            throw LumenOwnerAccountError.invalidInput
        case LumenEngineStatusAlreadyExists:
            throw duplicateError
        case LumenEngineStatusAuthenticationFailed:
            throw LumenOwnerAccountError.authenticationFailed
        case LumenEngineStatusStorageError:
            throw LumenOwnerAccountError.storageUnavailable
        case LumenEngineStatusCorruptData:
            throw LumenOwnerAccountError.corruptData
        default:
            throw LumenOwnerAccountError.engineStatus(status.rawValue)
        }
    }
}
