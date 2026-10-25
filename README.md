# CloudRedirect for macOS

A separate Apple Silicon app and Steam cloud-save runtime based on [CloudRedirect](https://github.com/crghofficial/cloudredirect). This repository is independent of macsteam and can coexist with its runtime.

## Requirements

- Apple Silicon Mac running macOS 15 or newer.
- ARM64 Steam installed at `/Applications/Steam.app`.
- A supported Steam client build. The runtime currently accepts the audited ARM64 Mach-O UUID `1D282616-B67E-30A6-B0AF-E4D5880610E7`; other builds remain inactive. The app's **Check Steam Compatibility** validates the interfaces and performs a real native protobuf round trip in an isolated helper process.
- Games with existing Steam Cloud / AutoCloud definitions. This port does not synthesize missing UFS rules or port upstream achievement/playtime synchronization.

## Use

1. Open **CloudRedirect.app**.
2. Choose a dedicated sync folder, Google Drive, OneDrive, S3, or Cloudflare R2. Sign in or configure credentials when required. Folder sync works with iCloud Drive and other folders managed by a separate sync client.
3. Enter the Steam app IDs to redirect, enable redirection, and save settings. Only selected IDs are intercepted; all other games pass through to Steam.
4. Quit Steam, then choose **Install Runtime**. Existing macsteam/NotProton injection entries are preserved. The installer adds only CloudRedirect's dylib and re-signs the Steam bundle locally.
5. Open Steam. Restart Steam after changing provider, game IDs, or the enable switch. Refresh the status in CloudRedirect to see the runtime's result.

**Check Provider** checks initialization and credential availability; remote access is exercised during game synchronization. **Remove Runtime** removes CloudRedirect's injection entry and library while retaining saves and configuration. Steam updates can replace the launcher configuration; reinstall the runtime afterwards if needed.

The app starts with redirection disabled. Opening it does not install anything, alter Steam, or select games automatically. The local build is ad-hoc signed, not notarized.

## Storage and credentials

Settings, local cached saves, operation journals and logs live in `~/Library/Application Support/CloudRedirect/`. The folder/provider format is compatible with upstream's content-addressed cloud save engine. Use a dedicated destination folder. Google Drive and OneDrive use browser OAuth with PKCE and state validation; an existing token JSON can also be imported. S3/R2 credentials are entered in the app.

Credentials are stored in the login Keychain, with access limited to the helper and installed Steam executables. Steam's background reads do not display authentication prompts; unavailable credentials leave startup redirection inactive. If Steam's code identity changes, sign in or save credentials again. No user secrets are bundled in the app or repository.

The runtime hooks Steam's ARM64 unified cloud RPC transport and cloud-enable interface. A localhost blob server accepts connections only when the peer socket belongs to the same Steam process. If the Steam build or native protobuf compatibility check fails, hooks are not installed. Once a remote provider is configured, upstream's local cache/journal handles offline work and retries.

## Build and test

Install Xcode command-line tools, Swift 6+, and CMake 3.20+. System libcurl and Security/Foundation frameworks are used; no third-party package download is required.

```sh
./scripts/macos/build.sh
swift test --package-path ui-macos
# Optional: requires the supported Steam client, does not install hooks in Steam.
./build-macos/macos_native_rpc_tests
```

The app and ZIP are emitted into `out/`, or into the directory passed to the build script. CTest covers folder transfers, traversal/symlink containment, concurrent atomic writes, worker shutdown, same-process blob-server isolation, and interrupted-upload journals. Swift tests cover installer preservation/removal of other injection entries and OAuth parameter encoding. The optional native test uses synthetic configuration and save data under a temporary directory and verifies selected-game interception plus unselected-game passthrough against Steam's real protobuf objects. Cloud-account sign-in and a live game's end-to-end sync require user configuration and are not covered by these tests.

The bundled CLI also exposes upstream's remote-save management commands, plus `diagnose`, `check-provider`, and `store-credentials PROVIDER` (JSON on stdin). Use `cloud_redirect_cli --help` for upstream CLI usage.

See [UPSTREAM.md](UPSTREAM.md), [the original README](README.upstream.md), and [LICENSE](LICENSE) for provenance and upstream documentation. Windows/Linux builds retain the upstream interfaces; the macOS UI and runtime are separate.
