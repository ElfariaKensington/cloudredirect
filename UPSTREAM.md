# Upstream attribution

CloudRedirect for macOS derives from [crghofficial/cloudredirect](https://github.com/crghofficial/cloudredirect), snapshot `00969da863c8d7b2e2821ebc2c6cb231bbe56ef2` (2026-10-25 checkout).

Original CloudRedirect code is copyright (c) 2026 Selectively11 and distributed under the MIT license in LICENSE. The Windows and Linux source trees are retained for attribution and comparison. The macOS port adds `src/platform/macos`, `ui-macos`, `cmake/macos.cmake`, native tests, and macOS build scripts; shared-code changes add native paths/platform matching and fix worker shutdown synchronization.

The native UI uses the same public desktop OAuth client registrations as upstream. These identify the OAuth applications; user access/refresh tokens and S3/R2 secrets are stored separately in the login Keychain.
