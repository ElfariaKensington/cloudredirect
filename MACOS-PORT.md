# macOS port branch

This branch is based on `crghofficial/cloudredirect` master at
`00969da863c8d7b2e2821ebc2c6cb231bbe56ef2`. The upstream default branch is retained.
The separate native macOS application and runtime live in this branch.

## Build

Requires Apple Silicon, macOS 15+, Xcode command line tools, CMake, and Qt 6
(Core, Quick, QuickControls2 and Network). Homebrew `qt` is supported.

```sh
git submodule update --init --recursive
./scripts/macos/build-full-ui.sh
```

The Qt application and ZIP are emitted into `out/full-ui/`. Pass a destination
folder to the script to change it. The original SwiftUI frontend remains
available with `./scripts/macos/build.sh`; the Qt bundle uses its installer as
a helper. Both builds are ad-hoc signed.

## Implemented in this branch

- Original Qt dashboard, provider configuration, OAuth, app management,
  backup/restore and migration screens, adapted to native macOS paths.
- Keychain credentials, native runtime installation preserving existing Steam
  injectors, manual app selection and automatic self-unlocking Lua discovery.
- ARM64 Steam cloud RPC redirection and native cloud configuration KV helpers.
- Native achievement/playtime hooks and shared stats/cloud merge code.
- Native manifest pinning with exact 64-bit IDs and per-app selection.
- Native Steam Cloud file manager, including AppID validation and explicit
  confirmation before deletion.
- Cross-device Lua archive merge and its configuration switch.

Internal Steam hooks require audited ARM64 Mach-O UUID
`1D282616-B67E-30A6-B0AF-E4D5880610E7`. Other builds fail compatibility checks.
Steam must restart after runtime or runtime-setting changes.

## Validation and remaining parity work

Automated tests cover cloud storage isolation, journals, stats session handling,
manifest parsing/vector updates, Lua archive merging, Qt app management and
backup/restore. Native integration diagnostics exercise actual Steam protobuf,
KV helpers and playtime response layouts in isolated helper processes. A
read-only connection to native Steam Cloud storage has also been exercised.
The initial cloud-save runtime uploaded Subnautica Below Zero saves to Google
Drive successfully. New achievement/playtime hooks and manifest application
still require end-to-end live-game verification. Restore from a real remote
provider has not yet been verified.

This is a port in progress, not complete Windows feature parity. The Windows
stats browser, advanced cleanup with undo, cloud orphan pruning, localization,
and native app auto-updates are not yet ported. The Qt interface currently
retains the Linux stats switches and local orphan scan. Flatpak updater methods
are inactive on macOS. The initial README describes the smaller SwiftUI build;
this document records the newer Qt branch's current scope.

See THIRD_PARTY.md for Qt and Dobby licensing and rebuild information.
