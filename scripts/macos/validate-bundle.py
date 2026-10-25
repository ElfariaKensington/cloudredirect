#!/usr/bin/env python3
"""Load every packaged QML page with isolated configuration and Steam data."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
# codesign --deep does not inspect loadable plugins in Resources.
for plugin in (app / "Contents/Resources/qml").rglob("*.dylib"):
    subprocess.run(["codesign", "--verify", "--strict", str(plugin)], check=True)
with tempfile.TemporaryDirectory(prefix="cloudredirect-bundle-check-") as directory:
    root = Path(directory)
    (root / "CloudRedirect").mkdir()
    (root / "steam/config").mkdir(parents=True)
    (root / "CloudRedirect/config.json").write_text(
        json.dumps({"provider": "local", "enabled": False})
    )
    env = os.environ.copy()
    for key in ("QT_PLUGIN_PATH", "QT_QPA_PLATFORM", "QML_IMPORT_PATH", "QML2_IMPORT_PATH", "DYLD_LIBRARY_PATH"):
        env.pop(key, None)
    env.update(CLOUDREDIRECT_CONFIG_HOME=directory,
               CLOUDREDIRECT_STEAM_HOME=str(root / "steam"))
    subprocess.run([str(app / "Contents/MacOS/CloudRedirect"), "--validate-pages"],
                   env=env, check=True, timeout=30)
