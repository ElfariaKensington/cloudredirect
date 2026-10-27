# CloudRedirect for macOS

The desktop app is built with SwiftUI and AppKit. Foundation handles configuration, Steam account discovery, game inventory, backups, manifest preferences, OAuth, and migration progress. Provider and Steam Cloud operations use the shared native C++ CLI tools.

Build with Apple Silicon, macOS 15+, Xcode command line tools and CMake:

```sh
git submodule update --init --recursive
./scripts/macos/build-full-ui.sh out
```

The app and ZIP are written to the destination directory. Choose a fresh destination for each build. No third-party GUI framework or Homebrew GUI dependency is required.

The app preserves the existing configuration, encrypted Keychain credentials, local saves, cached game names and recovery backups. The native runtime continues to implement Steam cloud redirection, stats/playtime syncing, manifest pins and Lua syncing. Setup compares installed executable content after normalizing code signatures, including the credential helper. A runtime update is only offered when the executable contents differ or a required helper is missing.

The former cross-platform desktop GUI and its packaging have been removed. Native runtime sources for other platforms remain in `src/platform`.

See `THIRD_PARTY.md` for native third-party components and license notices.
