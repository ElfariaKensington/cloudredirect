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
    func testOAuthFormEncodingDoesNotSplitSecretParameters() {
        XCTAssertEqual(OAuth.form(["key": "a&b+c=# space"]), "key=a%26b%2Bc%3D%23%20space")
    }
}
