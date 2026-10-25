import AppKit
import Foundation

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct RuntimeInstaller {
    static let steam = URL(fileURLWithPath: "/Applications/Steam.app")
    static let executableDirectory = steam.appendingPathComponent("Contents/MacOS")
    static let runtime = executableDirectory.appendingPathComponent("cloud_redirect.dylib")
    static var resources: URL { Bundle.main.resourceURL!.appendingPathComponent("runtime") }
    static var helper: URL { resources.appendingPathComponent("cloud_redirect_cli") }
    static func run(_ executable: URL, _ arguments: [String], input: Data? = nil) throws -> String {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        let stdin = Pipe(); process.standardInput = stdin
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AppError.message(result.isEmpty ? "Command failed (\(process.terminationStatus))." : result) }
        return result
    }
    static func ensureSteamClosed() throws {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.valvesoftware.steam" || $0.executableURL?.lastPathComponent == "steam_osx" }) {
            throw AppError.message("Quit Steam before installing or removing the runtime.")
        }
    }
    static func updateInjection(_ dictionary: inout [String: Any], installing: Bool) {
        var environment = dictionary["LSEnvironment"] as? [String: String] ?? [:]
        var libraries = (environment["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
        libraries.removeAll { URL(fileURLWithPath: $0).lastPathComponent == "cloud_redirect.dylib" }
        if installing { libraries.append(runtime.path) }
        if libraries.isEmpty { environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES") }
        else { environment["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":") }
        if environment.isEmpty { dictionary.removeValue(forKey: "LSEnvironment") }
        else { dictionary["LSEnvironment"] = environment }
    }
    static func install(_ installing: Bool) throws {
        try ensureSteamClosed()
        let fm = FileManager.default
        let plist = steam.appendingPathComponent("Contents/Info.plist")
        let originalPlist = try Data(contentsOf: plist)
        var dictionary = try PropertyListSerialization.propertyList(from: originalPlist, format: nil) as! [String: Any]
        let credentials = executableDirectory.appendingPathComponent("cloud_redirect_credentials")
        let oldCredentials = try? Data(contentsOf: credentials)
        let oldRuntime = try? Data(contentsOf: runtime)
        updateInjection(&dictionary, installing: installing)
        let updated = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        // All files live in the user-writable Steam bundle; no privileged helper.
        do {
            if installing {
                let broker = try Data(contentsOf: resources.appendingPathComponent("cloud_redirect_credentials"))
                try broker.write(to: credentials, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: credentials.path)
                let dylib = try Data(contentsOf: resources.appendingPathComponent("cloud_redirect.dylib"))
                try dylib.write(to: runtime, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
                _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", runtime.path])
            }
            try updated.write(to: plist, options: .atomic)
            // Do not re-sign macsteam, NotProton, or any other injected library.
            _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", steam.path])
            if !installing && fm.fileExists(atPath: credentials.path) { try fm.removeItem(at: credentials) }
            if !installing && fm.fileExists(atPath: runtime.path) { try fm.removeItem(at: runtime) }
            _ = try? run(URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"), ["-f", steam.path])
        } catch {
            if let oldCredentials { try? oldCredentials.write(to: credentials, options: .atomic) }
            else { try? fm.removeItem(at: credentials) }
            try? originalPlist.write(to: plist, options: .atomic)
            if let oldRuntime { try? oldRuntime.write(to: runtime, options: .atomic) }
            else { try? fm.removeItem(at: runtime) }
            _ = try? run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", steam.path])
            throw error
        }
    }
}
