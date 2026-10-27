import AppKit
import Foundation

public enum AppError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public struct RuntimeInstaller {
    public static let steam = URL(fileURLWithPath: "/Applications/Steam.app")
    public static let executableDirectory = steam.appendingPathComponent("Contents/MacOS")
    public static let runtime = executableDirectory.appendingPathComponent("cloud_redirect.dylib")
    public static var resources: URL { Bundle.main.resourceURL!.appendingPathComponent("runtime") }
    public static var helper: URL { resources.appendingPathComponent("cloud_redirect_cli") }
    public static func run(_ executable: URL, _ arguments: [String], input: Data? = nil) throws -> String {
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
    public static func ensureSteamClosed() throws {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.valvesoftware.steam" || $0.executableURL?.lastPathComponent == "steam_osx" }) {
            throw AppError.message("Quit Steam before installing or removing the runtime.")
        }
    }
    public static func updateInjection(_ dictionary: inout [String: Any], installing: Bool) {
        var environment = dictionary["LSEnvironment"] as? [String: String] ?? [:]
        var libraries = (environment["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
        libraries.removeAll { URL(fileURLWithPath: $0).lastPathComponent == "cloud_redirect.dylib" }
        if installing { libraries.append(runtime.path) }
        if libraries.isEmpty { environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES") }
        else { environment["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":") }
        if environment.isEmpty { dictionary.removeValue(forKey: "LSEnvironment") }
        else { dictionary["LSEnvironment"] = environment }
    }
    public static func stageCredentialHelper(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let sourceData = try Data(contentsOf: source)
        if fm.fileExists(atPath: destination.path) {
            guard fm.isExecutableFile(atPath: destination.path) else {
                throw AppError.message("The installed credential helper is not executable.")
            }
            if try Data(contentsOf: destination) == sourceData { return }
            if try RuntimeContent.fingerprint(source) == RuntimeContent.fingerprint(destination) { return }
        }
        try sourceData.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    public static func install(_ installing: Bool) throws {
        try ensureSteamClosed()
        let fm = FileManager.default
        let plist = steam.appendingPathComponent("Contents/Info.plist")
        let originalPlist = try Data(contentsOf: plist)
        var dictionary = try PropertyListSerialization.propertyList(from: originalPlist, format: nil) as! [String: Any]
        let credentials = executableDirectory.appendingPathComponent("cloud_redirect_credentials")
        let hadCredentials = fm.fileExists(atPath: credentials.path)
        let oldCredentials = try? Data(contentsOf: credentials)
        let oldRuntime = try? Data(contentsOf: runtime)
        updateInjection(&dictionary, installing: installing)
        let updated = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        // All files live in the user-writable Steam bundle; no privileged helper.
        do {
            if installing {
                try stageCredentialHelper(from: resources.appendingPathComponent("cloud_redirect_credentials"), to: credentials)
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
            if let oldCredentials {
                try? oldCredentials.write(to: credentials, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: credentials.path)
            } else if !hadCredentials { try? fm.removeItem(at: credentials) }
            try? originalPlist.write(to: plist, options: .atomic)
            if let oldRuntime { try? oldRuntime.write(to: runtime, options: .atomic) }
            else { try? fm.removeItem(at: runtime) }
            _ = try? run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", steam.path])
            throw error
        }
    }
}
