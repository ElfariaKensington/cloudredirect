import XCTest
@testable import CloudRedirect
final class InstallerTests: XCTestCase {
    func testInstallAndRemovalPreserveOtherInjectorsAndEnvironment() {
        let existing = "/Applications/Steam.app/Contents/MacOS/macsteam.dylib:/Applications/Steam.app/Contents/MacOS/notproton.dylib"
        var plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "LSEnvironment": ["DYLD_INSERT_LIBRARIES": existing, "CUSTOM_SETTING": "preserved"]]
        RuntimeInstaller.updateInjection(&plist, installing: true)
        RuntimeInstaller.updateInjection(&plist, installing: true)
        var environment = plist["LSEnvironment"] as! [String: String]
        XCTAssertEqual(environment["DYLD_INSERT_LIBRARIES"], existing + ":" + RuntimeInstaller.runtime.path)
        XCTAssertEqual(environment["CUSTOM_SETTING"], "preserved")
        RuntimeInstaller.updateInjection(&plist, installing: false)
        environment = plist["LSEnvironment"] as! [String: String]
        XCTAssertEqual(environment["DYLD_INSERT_LIBRARIES"], existing)
        XCTAssertEqual(environment["CUSTOM_SETTING"], "preserved")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.valvesoftware.steam")
    }
    func testRemovalOfOnlyInjectorClearsEmptyEnvironment() {
        var plist: [String: Any] = [:]
        RuntimeInstaller.updateInjection(&plist, installing: true)
        RuntimeInstaller.updateInjection(&plist, installing: false)
        XCTAssertNil(plist["LSEnvironment"])
    }
    func testCredentialHelperIdentityIsPreservedOnUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled")
        let installed = root.appendingPathComponent("installed")
        try Data("trusted-build".utf8).write(to: installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        try Data("new-build".utf8).write(to: bundled)
        try RuntimeInstaller.stageCredentialHelper(from: bundled, to: installed)
        XCTAssertEqual(try Data(contentsOf: installed), Data("trusted-build".utf8))
    }
    func testFirstInstallStagesExecutableCredentialHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled")
        let installed = root.appendingPathComponent("installed")
        try Data("new-build".utf8).write(to: bundled)
        try RuntimeInstaller.stageCredentialHelper(from: bundled, to: installed)
        XCTAssertEqual(try Data(contentsOf: installed), Data("new-build".utf8))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
    }
    func testOAuthFormEncodingDoesNotSplitSecretParameters() {
        XCTAssertEqual(OAuth.form(["key": "a&b+c=# space"]), "key=a%26b%2Bc%3D%23%20space")
    }
}
