import Foundation
import LumenMacBridge
import XCTest

final class LumenApplicationCatalogStoreTests: XCTestCase {
    func testCatalogPersistsAndReordersNativeApplications() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("apps.json")
        let store = try LumenApplicationCatalogStore(fileURL: fileURL)

        try await store.save(LumenApplication(name: "Desktop"))
        try await store.save(LumenApplication(name: "Editor", command: "open -a TextEdit"))
        var applications = try await store.applications()
        XCTAssertEqual(applications.map(\.name), ["Desktop", "Editor"])
        XCTAssertTrue(applications.allSatisfy { !$0.id.isEmpty })

        try await store.reorder(applicationIDs: applications.reversed().map(\.id))
        applications = try await store.applications()
        XCTAssertEqual(applications.map(\.name), ["Editor", "Desktop"])

        try await store.delete(applicationID: applications[0].id)
        applications = try await store.applications()
        XCTAssertEqual(applications.map(\.name), ["Desktop"])
    }

    func testCatalogRoundTripsRuntimeApplicationFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LumenApplicationCatalogStore(
            fileURL: root.appendingPathComponent("apps.json")
        )
        let application = LumenApplication(
            name: "Game",
            command: "game --stream",
            detachedCommands: ["helper --start"],
            preparationCommands: [.init(run: "prepare", undo: "restore")],
            workingDirectory: "/Applications/Game",
            virtualDisplay: true,
            scaleFactor: 125,
            terminateOnPause: true
        )

        try await store.save(application)
        let savedApplications = try await store.applications()
        let saved = try XCTUnwrap(savedApplications.first)
        XCTAssertEqual(saved.name, application.name)
        XCTAssertEqual(saved.command, application.command)
        XCTAssertEqual(saved.detachedCommands, application.detachedCommands)
        XCTAssertEqual(saved.preparationCommands, application.preparationCommands)
        XCTAssertEqual(saved.workingDirectory, application.workingDirectory)
        XCTAssertEqual(saved.virtualDisplay, application.virtualDisplay)
        XCTAssertEqual(saved.scaleFactor, application.scaleFactor)
        XCTAssertEqual(saved.terminateOnPause, application.terminateOnPause)
    }

    func testCatalogLoadsOptionalRuntimeCommandFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("apps.json")
        try Data(#"{"apps":[{"name":"Desktop","prep-cmd":[{"undo":"close"}]}]}"#.utf8)
            .write(to: fileURL)

        let store = try LumenApplicationCatalogStore(fileURL: fileURL)
        let applications = try await store.applications()
        let command = try XCTUnwrap(applications.first?.preparationCommands.first)
        XCTAssertEqual(command.run, "")
        XCTAssertEqual(command.undo, "close")
        XCTAssertFalse(command.elevated)
    }
}
