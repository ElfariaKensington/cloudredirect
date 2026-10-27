# Third-party components

The macOS runtime statically links [Dobby](https://github.com/jmpews/Dobby) at commit `5dfc8546954ce3b3198132ab13fddb89ee92cdd7`, under the Apache License 2.0 (`licenses/Dobby-Apache-2.0.txt`). Initialize this pinned submodule with `git submodule update --init --recursive` after cloning.

The macOS desktop interface uses Apple SwiftUI, AppKit, Foundation, CryptoKit and Security frameworks. Cloud operations use the shared native C++ provider implementations.

The original CloudRedirect code and its embedded third-party notices are retained; see `LICENSE` and `UPSTREAM.md`. Apple platform frameworks and system libcurl are used from macOS.
