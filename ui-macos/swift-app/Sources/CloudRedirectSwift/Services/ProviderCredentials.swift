import Foundation
import Security

enum ProviderCredentials {
    // Match only this provider's credential path; preserve other provider accounts.
    static func disconnect(path: String) -> OSStatus {
        guard !path.isEmpty else { return errSecParam }
        let helper = URL(fileURLWithPath: "/Applications/Steam.app/Contents/MacOS/cloud_redirect_credentials")
        let capability = Process()
        capability.executableURL = helper
        capability.arguments = ["supports-delete"]
        do { try capability.run(); capability.waitUntilExit() } catch { return errSecUnimplemented }
        guard capability.terminationStatus == 0 else { return errSecUnimplemented }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["delete", path, "--interactive"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? errSecSuccess : errSecAuthFailed
        } catch {
            return errSecUnimplemented
        }
    }
}
