import Foundation
import Darwin

// Command-line installer used by the Qt interface. This helper has no UI.
@main struct CloudRedirectInstaller {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["--install-runtime"] || arguments == ["--remove-runtime"] else {
            fputs("Usage: CloudRedirectNative --install-runtime | --remove-runtime\n", stderr)
            exit(2)
        }
        do {
            try RuntimeInstaller.install(arguments == ["--install-runtime"])
            print("Runtime operation completed")
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            exit(1)
        }
    }
}
