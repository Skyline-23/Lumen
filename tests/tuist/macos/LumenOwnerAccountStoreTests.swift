import Foundation
import XCTest
@testable import LumenMacBridge

final class LumenOwnerAccountStoreTests: XCTestCase {
    func testOwnerAccountStoreCreatesAndVerifiesOwner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let store = try LumenOwnerAccountStore(
            fileURL: root.appendingPathComponent("owner-account.json")
        )

        let initialState = await store.state()
        XCTAssertEqual(initialState, .uninitialized)
        try await store.createOwner(
            username: "owner",
            password: "correct horse battery staple"
        )

        let readyState = await store.state()
        let ownerUsername = try await store.username()
        XCTAssertEqual(readyState, .ready)
        XCTAssertEqual(ownerUsername, "owner")
        try await store.verifyOwner(
            username: "owner",
            password: "correct horse battery staple"
        )
        await XCTAssertThrowsErrorAsync(
            try await store.verifyOwner(username: "owner", password: "incorrect password")
        ) { error in
            XCTAssertEqual(error as? LumenOwnerAccountError, .authenticationFailed)
        }
    }

    func testOwnerAccountStoreRejectsShortPasswords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let store = try LumenOwnerAccountStore(
            fileURL: root.appendingPathComponent("owner-account.json")
        )

        await XCTAssertThrowsErrorAsync(
            try await store.createOwner(username: "owner", password: "short")
        ) { error in
            XCTAssertEqual(error as? LumenOwnerAccountError, .invalidInput)
        }
        let state = await store.state()
        XCTAssertEqual(state, .uninitialized)
    }

    func testOwnerAccountStoreEnrollsAndRevokesDeviceCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let store = try LumenOwnerAccountStore(
            fileURL: root.appendingPathComponent("owner-account.json"),
            deviceFileURL: root.appendingPathComponent("devices.json")
        )
        try await store.createOwner(
            username: "owner",
            password: "correct horse battery staple"
        )

        let enrollment = try await store.enrollDevice(
            ownerPassword: "correct horse battery staple",
            name: "Living Room Tablet",
            platform: "ios",
            publicKey: "MCowBQYDK2VwAyEAu2y4x9h0B5y3lQ8xY7jW4C6Q7m8n9p0a1b2c3d4e5f6="
        )
        XCTAssertFalse(enrollment.deviceID.isEmpty)
        XCTAssertFalse(enrollment.refreshToken.isEmpty)
        let enrolledDeviceCount = await store.activeDeviceCount()
        XCTAssertEqual(enrolledDeviceCount, 1)
        try await store.verifyRefreshToken(
            deviceID: enrollment.deviceID,
            refreshToken: enrollment.refreshToken
        )

        try await store.revokeDevice(
            deviceID: enrollment.deviceID,
            ownerPassword: "correct horse battery staple"
        )
        let revokedDeviceCount = await store.activeDeviceCount()
        XCTAssertEqual(revokedDeviceCount, 0)
        await XCTAssertThrowsErrorAsync(
            try await store.verifyRefreshToken(
                deviceID: enrollment.deviceID,
                refreshToken: enrollment.refreshToken
            )
        ) { error in
            XCTAssertEqual(error as? LumenOwnerAccountError, .authenticationFailed)
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
