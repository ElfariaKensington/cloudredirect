"""Isolated cloud inventory/deletion integration checks; pass the native CLI path."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
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
        "save.dat": {"size": 7}, "keep.sav": {"size": 5}, "removed.sav": {"size": 9, "ps": 2}}}))
    result, data = run()
    assert result.returncode == 0 and len(data["files"]) == 2 and data["totalSize"] == 12
    before = state.read_bytes()
    missing = subprocess.run([cli, "delete-cloud-save-files", "folder", "4242", "620", "--confirmed", "missing.dat"], capture_output=True, text=True, env=env, timeout=10)
    assert missing.returncode != 0 and state.read_bytes() == before
    deleted = subprocess.run([cli, "delete-cloud-save-files", "folder", "4242", "620", "--confirmed", "save.dat"], capture_output=True, text=True, env=env, timeout=10)
    assert deleted.returncode == 0
    after = json.loads(state.read_text())
    assert after["cn"] == 2 and after["files"]["save.dat"]["ps"] == 2
    assert after["files"]["removed.sav"]["ps"] == 2
    backups = list((config / "cloud-file-backups").glob("*.json"))
    assert len(backups) == 1 and backups[0].read_bytes() == before
    result, data = run()
    assert [f["name"] for f in data["files"]] == ["keep.sav"] and data["totalSize"] == 5
    state.write_text(json.dumps({"v": 2, "cn": 2, "session": {"client_id": "42", "op": "active", "time": time.time()}, "files": {"save.dat": {"size": 7}}}))
    before = state.read_bytes()
    active = subprocess.run([cli, "delete-cloud-save-files", "folder", "4242", "620", "--confirmed", "save.dat"], capture_output=True, text=True, env=env, timeout=10)
    assert active.returncode != 0 and state.read_bytes() == before
    state.unlink()
    (app / "manifest.cloudredirect").write_text(json.dumps({"legacy.sav": {"size": 11}}))
    result, data = run()
    assert result.returncode == 0 and data["totalSize"] == 11
    state.write_text("broken")
    result, data = run()
    assert result.returncode != 0 and not data["success"]
print("Cloud inventory, deletion, backup, active-session protection and error checks passed")
