import XCTest
import CloudRedirectSupport
@testable import CloudRedirectSwift

final class NativeBackendTests: XCTestCase {
    func fixture() throws -> (URL, NativeStorage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, NativeStorage(environment: ["CLOUDREDIRECT_CONFIG_HOME": root.path, "CLOUDREDIRECT_STEAM_HOME": root.appendingPathComponent("steam").path]))
    }
    func testSteamAccountPrefersMostRecentOverTimestamp() throws {
        let (root, disk) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let vdf = #""users" { "76561197960265729" { "PersonaName" "Recent" "MostRecent" "1" "Timestamp" "1" } "76561197960265730" { "PersonaName" "Older" "Timestamp" "9999" } }"#
        let url = disk.steam.appendingPathComponent("config/loginusers.vdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try vdf.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(disk.account().id, "1"); XCTAssertEqual(disk.account().name, "Recent")
    }
    func testLocalInventoryIgnoresMetadataAndSymbolicLinks() throws {
        let (root, disk) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = disk.storage.appendingPathComponent("1/620")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: app.appendingPathComponent("blobs/data"))
        try Data("metadata".utf8).write(to: app.appendingPathComponent("cn.dat"))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("link"), withDestinationURL: app.appendingPathComponent("cn.dat"))
        let games = disk.localGames(account: "1", cache: ["620": ["name": "Portal 2"]])
        XCTAssertEqual(games.count, 1); XCTAssertEqual(number(games[0], "fileCount"), 1)
        XCTAssertEqual(number(games[0], "totalSize"), 4)
        XCTAssertEqual(string(games[0], "name"), "Portal 2")
    }
    @MainActor func testNativeSettingsPreserveUnmanagedConfigAndSaveManifestPreferences() async throws {
        let (root, disk) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try disk.write(["provider": "local", "apps": [620], "custom": "retained", "token_paths": ["gdrive": "/token"]], to: disk.configURL)
        let store = BackendStore(startup: false)
        let native = NativeBackend(store: store, disk: disk)
        try await native.set("notificationsEnabled", value: false)
        _ = try await native.invoke("saveManifestSettings", args: [true, false, [620]], target: "backend")
        let config = disk.json(disk.configURL)
        XCTAssertEqual(config["custom"] as? String, "retained")
        XCTAssertEqual(config["apps"] as? [Int], [620])
        XCTAssertEqual(config["pinned_apps"] as? [Int], [620])
        XCTAssertEqual((config["token_paths"] as? [String: String])?["gdrive"], "/token")
        XCTAssertEqual(config["notifications_enabled"] as? Bool, false)
    }
    @MainActor func testRestoreRejectsEscapeThroughBackupSymlink() async throws {
        let (root, disk) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendStore(startup: false)
        let backend = NativeBackend(store: store, disk: disk); backend.account = ("1", "Test")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backend.backupRoot, withIntermediateDirectories: true)
        let link = backend.backupRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try backend.validBackup(link.path))
        XCTAssertThrowsError(try backend.validBackup(backend.backupRoot.path))
    }
    func testCommandJSONHandlesNestedErrorsWithoutLosingMessage() throws {
        let result = NativeCommandResult(data: Data("diagnostic\n{\"success\":false,\"error\":\"Specific failure\",\"details\":{\"n\":1}}\n".utf8), errors: "", status: 1)
        XCTAssertThrowsError(try result.json()) { XCTAssertEqual($0.localizedDescription, "Specific failure") }
    }
}
