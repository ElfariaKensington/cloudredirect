# Third-party components

The macOS runtime statically links [Dobby](https://github.com/jmpews/Dobby) at commit `5dfc8546954ce3b3198132ab13fddb89ee92cdd7`, under the Apache License 2.0 (`licenses/Dobby-Apache-2.0.txt`). Initialize this pinned submodule with `git submodule update --init --recursive` after cloning.

The full desktop interface dynamically links Qt 6, provided by Homebrew's `qtbase` and `qtdeclarative` packages. Qt is available under the LGPL 3.0; copies of the LGPL and its incorporated GPL text are included in `licenses/`. The bundle keeps Qt frameworks as replaceable dynamic libraries. The build scripts and source let users rebuild/relink the application with a modified Qt, then ad-hoc sign the result. Corresponding Qt source is available from https://code.qt.io/cgit/qt/qtbase.git/ and https://code.qt.io/cgit/qt/qtdeclarative.git/ (use the tag matching `brew list --versions qtbase qtdeclarative`, currently v6.12.0). Qt's source distributions retain the notices for bundled dependencies. No DRM or installation restriction prevents a locally rebuilt app from running.

The original CloudRedirect code and its embedded third-party notices are retained; see `LICENSE` and `UPSTREAM.md`. Apple platform frameworks and system libcurl are used from macOS.
