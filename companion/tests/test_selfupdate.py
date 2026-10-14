"""Tests for the companion self-update (download, unpack, swap script)."""

import hashlib
import io
import subprocess
import sys
import tarfile
import time
import zipfile
from pathlib import Path

import pytest

from shuffledetector import selfupdate as su


def release(**assets):
    return {"tag": "v9.9.9", "url": "https://example/rel", "assets": assets, "digests": {}}


def make_zip(path, entries):
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    return Path(path)


def make_tar(path, entries):
    with tarfile.open(path, "w:gz") as tf:
        for name, data in entries.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755
            tf.addfile(info, io.BytesIO(data))
    return Path(path)


def test_companion_asset_picks_this_platform():
    rel = release(**{
        "ShuffleDetector-0.3.0.zip": "addon",
        "ShuffleDetector-Companion-v0.3.0-windows.zip": "win",
        "ShuffleDetector-Companion-v0.3.0-macos.zip": "mac",
        "ShuffleDetector-Companion-v0.3.0-linux.tar.gz": "lin",
    })
    assert su.companion_asset(rel, "win32") == ("ShuffleDetector-Companion-v0.3.0-windows.zip", "win")
    assert su.companion_asset(rel, "darwin")[1] == "mac"
    assert su.companion_asset(rel, "linux")[1] == "lin"
    assert su.companion_asset(release(**{"ShuffleDetector-0.3.0.zip": "addon"}), "win32") == (None, None)


def test_app_root(tmp_path):
    assert su.app_root(tmp_path / "App" / "x.exe", "win32") == (tmp_path / "App").resolve()
    exe = tmp_path / "X.app" / "Contents" / "MacOS" / "X"
    assert su.app_root(exe, "darwin") == (tmp_path / "X.app").resolve()
    assert su.app_root(tmp_path / "x", "darwin") is None


@pytest.mark.parametrize("bad", ["../evil.txt", "/abs.txt", "a/../../evil.txt", "C:/evil.txt"])
def test_extract_refuses_escaping_paths(tmp_path, bad):
    with pytest.raises(su.UpdateError):
        su.extract_zip(make_zip(tmp_path / "a.zip", {bad: "x"}), tmp_path / "out")
    if not bad.startswith("C:"):
        with pytest.raises(su.UpdateError):
            su.extract_tar(make_tar(tmp_path / "a.tar.gz", {bad: b"x"}), tmp_path / "out")
    assert not (tmp_path / "evil.txt").exists()


def test_extract_refuses_escaping_symlink(tmp_path):
    with tarfile.open(tmp_path / "l.tar.gz", "w:gz") as tf:
        info = tarfile.TarInfo("App/link")
        info.type = tarfile.SYMTYPE
        info.linkname = "../../outside"
        tf.addfile(info)
    with pytest.raises(su.UpdateError):
        su.extract_tar(tmp_path / "l.tar.gz", tmp_path / "out")


def test_verify_digest(tmp_path):
    f = tmp_path / "f"
    f.write_bytes(b"data")
    su.verify_digest(f, None)
    su.verify_digest(f, "sha256:" + hashlib.sha256(b"data").hexdigest())
    with pytest.raises(su.UpdateError):
        su.verify_digest(f, "sha256:" + "0" * 64)


def installed(tmp_path):
    root = tmp_path / "ShuffleDetector-Companion"
    root.mkdir()
    (root / "old.txt").write_text("old")
    return root


def test_stage_update_windows_zip(tmp_path):
    root = installed(tmp_path)
    archive = make_zip(tmp_path / "dl.zip", {
        "ShuffleDetector-Companion/ShuffleDetector-Companion.exe": "exe",
        "ShuffleDetector-Companion/_internal/lib.dll": "dll",
    })
    rel = release(**{"ShuffleDetector-Companion-v9.9.9-windows.zip": archive.as_uri()})
    seen = []
    new_root = su.stage_update(rel, lambda d, t: seen.append((d, t)), platform="win32", root=root)
    assert new_root == tmp_path / "ShuffleDetector-Companion.new"
    assert (new_root / "ShuffleDetector-Companion.exe").read_text() == "exe"
    assert (new_root / "_internal" / "lib.dll").is_file()
    assert (root / "old.txt").exists()  # installed copy untouched until the swap script runs
    assert not (tmp_path / "ShuffleDetector-Companion.update").exists()
    assert seen and seen[-1][0] == seen[-1][1] > 0


def test_stage_update_linux_tar_keeps_exec_bit(tmp_path):
    root = installed(tmp_path)
    archive = make_tar(tmp_path / "dl.tar.gz", {"ShuffleDetector-Companion/ShuffleDetector-Companion": b"bin"})
    rel = release(**{"ShuffleDetector-Companion-v9.9.9-linux.tar.gz": archive.as_uri()})
    new_root = su.stage_update(rel, platform="linux", root=root)
    assert (new_root / "ShuffleDetector-Companion").read_bytes() == b"bin"
    if sys.platform != "win32":
        assert (new_root / "ShuffleDetector-Companion").stat().st_mode & 0o111


def test_stage_update_bad_digest_or_content_leaves_nothing(tmp_path):
    root = installed(tmp_path)
    archive = make_zip(tmp_path / "dl.zip", {"ShuffleDetector-Companion/ShuffleDetector-Companion.exe": "exe"})
    name = "ShuffleDetector-Companion-v9.9.9-windows.zip"
    rel = release(**{name: archive.as_uri()})
    rel["digests"] = {name: "sha256:" + "0" * 64}
    with pytest.raises(su.UpdateError):
        su.stage_update(rel, platform="win32", root=root)

    empty = make_zip(tmp_path / "empty.zip", {"ShuffleDetector-Companion/readme.txt": "x"})
    with pytest.raises(su.UpdateError):
        su.stage_update(release(**{name: empty.as_uri()}), platform="win32", root=root)
    assert sorted(p.name for p in tmp_path.iterdir() if p.name.startswith("ShuffleDetector-Companion")) == ["ShuffleDetector-Companion"]


def test_stage_update_without_matching_asset(tmp_path):
    with pytest.raises(su.UpdateError):
        su.stage_update(release(), platform="win32", root=installed(tmp_path))


def test_clean_environment_drops_bootloader_state():
    env = su.clean_environment({"_PYI_APPLICATION_HOME_DIR": "x", "_PYI_ARCHIVE_FILE": "y", "PATH": "p",
                                "LD_LIBRARY_PATH": "new", "LD_LIBRARY_PATH_ORIG": "orig"}, "linux")
    assert "_PYI_ARCHIVE_FILE" not in env and env["PATH"] == "p"
    assert env["LD_LIBRARY_PATH"] == "orig" and "LD_LIBRARY_PATH_ORIG" not in env
    assert env["PYINSTALLER_RESET_ENVIRONMENT"] == "1"
    assert "LD_LIBRARY_PATH" not in su.clean_environment({"LD_LIBRARY_PATH": "x"}, "linux")


def test_helper_scripts_mention_the_paths(tmp_path):
    root, new = tmp_path / "App Dir", tmp_path / "App Dir.new"
    win = su.build_helper_script(root, new, 123, "win32")
    assert f'move "{root}" "{root}.old"' in win and f'start "" "{root / "ShuffleDetector-Companion.exe"}"' in win
    mac = su.build_helper_script(tmp_path / "X.app", tmp_path / "X.app.new", 123, "darwin")
    assert "kill -0 123" in mac and mac.rstrip().endswith('rm -f "$0"') and "open " in mac
    assert "'" in su.build_helper_script(root, new, 123, "linux")  # path with a space is quoted


@pytest.mark.skipif(sys.platform == "win32", reason="runs the POSIX swap script")
def test_posix_helper_swaps_and_relaunches(tmp_path):
    root = installed(tmp_path)
    exe = root / "ShuffleDetector-Companion"
    new = tmp_path / "ShuffleDetector-Companion.new"
    new.mkdir()
    marker = tmp_path / "launched"
    (new / "ShuffleDetector-Companion").write_text(f"#!/bin/sh\necho started > {marker}\n")
    (new / "ShuffleDetector-Companion").chmod(0o755)
    script = tmp_path / "update.sh"
    script.write_text(su.build_helper_script(root, new, 2**22 + 1, "linux"))
    subprocess.run(["/bin/sh", str(script)], check=True)
    for _ in range(50):
        if marker.exists():
            break
        time.sleep(0.1)
    assert marker.exists() and exe.is_file() and not (root / "old.txt").exists()
    assert not (tmp_path / "ShuffleDetector-Companion.old").exists() and not script.exists()
