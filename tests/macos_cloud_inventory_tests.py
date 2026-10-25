"""Read-only cloud inventory integration checks; pass the native CLI path."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cli = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    config = root / "CloudRedirect"
    config.mkdir()
    remote = root / "remote"
    app = remote / "4242/620"
    app.mkdir(parents=True)
    (config / "config.json").write_text(json.dumps({"provider": "folder", "sync_path": str(remote)}))
    env = dict(os.environ, CLOUDREDIRECT_CONFIG_HOME=directory)

    def run():
        result = subprocess.run([cli, "list-cloud-save-files", "folder", "4242", "620"],
                                capture_output=True, text=True, env=env, timeout=10)
        return result, json.loads(result.stdout)

    state = app / "state.cloudredirect"
    state.write_text(json.dumps({"v": 2, "cn": 1, "files": {
        "save.dat": {"size": 7}, "deleted.dat": {"size": 9, "ps": 2}}}))
    result, data = run()
    assert result.returncode == 0 and len(data["files"]) == 1 and data["totalSize"] == 7
    state.unlink()
    (app / "manifest.cloudredirect").write_text(json.dumps({"legacy.sav": {"size": 11}}))
    result, data = run()
    assert result.returncode == 0 and data["totalSize"] == 11
    state.write_text("broken")
    result, data = run()
    assert result.returncode != 0 and not data["success"]
print("Cloud inventory state, deletion filtering, legacy fallback and errors passed")
