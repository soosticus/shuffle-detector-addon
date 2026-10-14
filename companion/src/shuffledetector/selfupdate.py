"""Replace a packaged (PyInstaller onedir) companion with a newer release from GitHub.

The running program cannot overwrite itself, so the new build is downloaded and unpacked next to the
installed one, then a small detached script waits for this process to exit, swaps the folders and
relaunches. Only the project's own GitHub release assets are downloaded.
"""

import hashlib
import os
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

APP_NAME = "ShuffleDetector-Companion"
PLATFORM_SUFFIX = {"windows": "-windows.zip", "macos": "-macos.zip", "linux": "-linux.tar.gz"}


LOG_REDIRECT = '>>"%LOG%" 2>&1'


class UpdateError(Exception):
    pass


def platform_key(platform=None):
    p = platform or sys.platform
    return "windows" if p.startswith("win") else "macos" if p == "darwin" else "linux"


def is_frozen():
    return bool(getattr(sys, "frozen", False))


def app_root(exe=None, platform=None):
    """The folder (or macOS .app bundle) that holds the installed companion, or None if unknown."""
    exe = Path(exe or sys.executable).resolve()
    if platform_key(platform) == "macos":
        return next((p for p in exe.parents if p.suffix == ".app"), None)
    return exe.parent


def can_self_update():
    root = app_root() if is_frozen() else None
    return bool(root and os.access(root, os.W_OK) and os.access(root.parent, os.W_OK))


def companion_asset(release, platform=None):
    """(name, url) of this platform's companion build in a release, or (None, None)."""
    suffix = PLATFORM_SUFFIX[platform_key(platform)]
    for name, url in release["assets"].items():
        if name.startswith(APP_NAME) and name.endswith(suffix):
            return name, url
    return None, None


def inner_exe(platform=None):
    """Path of the executable inside a freshly unpacked build, relative to its root."""
    key = platform_key(platform)
    if key == "windows":
        return Path(f"{APP_NAME}.exe")
    if key == "macos":
        return Path("Contents") / "MacOS" / APP_NAME
    return Path(APP_NAME)


def archive_root_name(platform=None):
    return f"{APP_NAME}.app" if platform_key(platform) == "macos" else APP_NAME


def download(url, dest, progress=None, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": "ShuffleDetector-updater"})
    with urllib.request.urlopen(req, timeout=timeout) as resp, open(dest, "wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if progress:
                progress(done, total)


def verify_digest(path, digest):
    """Check a file against GitHub's "sha256:<hex>" asset digest, when the release provides one."""
    if not digest or not digest.startswith("sha256:"):
        return
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != digest.split(":", 1)[1].lower():
        raise UpdateError("The downloaded file does not match the checksum GitHub published for it.")


def _safe_name(name):
    parts = Path(name.replace("\\", "/")).parts
    return not (os.path.isabs(name) or name.startswith(("/", "\\")) or ".." in parts or (parts and ":" in parts[0]))


def extract_zip(archive, dest):
    dest = Path(dest)
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            if not _safe_name(info.filename):
                raise UpdateError(f"Unsafe path in the update archive: {info.filename}")
        if platform_key() == "macos" and shutil.which("ditto"):  # keeps symlinks and permissions inside the .app
            dest.mkdir(parents=True, exist_ok=True)
            subprocess.run(["ditto", "-x", "-k", str(archive), str(dest)], check=True)
            return
        for info in zf.infolist():
            target = dest / info.filename
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)
            mode = (info.external_attr >> 16) & 0o777
            if mode:
                os.chmod(target, mode)


def extract_tar(archive, dest):
    dest = Path(dest)
    with tarfile.open(archive) as tf:
        for m in tf.getmembers():
            if not _safe_name(m.name):
                raise UpdateError(f"Unsafe path in the update archive: {m.name}")
            if m.issym() and not _safe_name(os.path.join(os.path.dirname(m.name), m.linkname)):
                raise UpdateError(f"Unsafe link in the update archive: {m.name}")
            if m.islnk() and not _safe_name(m.linkname):
                raise UpdateError(f"Unsafe link in the update archive: {m.name}")
            if not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
                raise UpdateError(f"Unexpected entry type in the update archive: {m.name}")
        dest.mkdir(parents=True, exist_ok=True)
        if hasattr(tarfile, "data_filter"):
            tf.extractall(dest, filter="data")
        else:
            tf.extractall(dest)


def extract(archive, dest):
    (extract_tar if str(archive).endswith((".tar.gz", ".tgz")) else extract_zip)(archive, dest)


def stage_update(release, progress=None, platform=None, root=None):
    """Download and unpack the release's build next to the installed one. Returns the staged folder."""
    name, url = companion_asset(release, platform)
    if not name:
        raise UpdateError(f"Release {release['tag']} has no {platform_key(platform)} companion build.")
    root = Path(root) if root else app_root(platform=platform)
    if root is None or not (os.access(root, os.W_OK) and os.access(root.parent, os.W_OK)):
        raise UpdateError("The companion folder is not writable, so it cannot replace itself. Download the new build yourself.")
    new_root = root.with_name(root.name + ".new")
    scratch = root.with_name(root.name + ".update")
    for p in (new_root, scratch):
        shutil.rmtree(p, ignore_errors=True)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / name
            download(url, archive, progress)
            verify_digest(archive, release.get("digests", {}).get(name))
            extract(archive, scratch)
        unpacked = scratch / archive_root_name(platform)
        if not (unpacked / inner_exe(platform)).is_file():
            raise UpdateError("The downloaded build does not contain the companion program.")
        unpacked.rename(new_root)
    except BaseException:
        shutil.rmtree(new_root, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return new_root


def clean_environment(env=None, platform=None):
    """Environment for relaunching: drop the bootloader state PyInstaller leaves in the running process."""
    env = dict(os.environ if env is None else env)
    for k in [k for k in env if k.startswith("_PYI")]:
        del env[k]
    env["PYINSTALLER_RESET_ENVIRONMENT"] = "1"
    if platform_key(platform) != "windows":
        for var in ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"):
            orig = env.pop(var + "_ORIG", None)
            if orig is None:
                env.pop(var, None)
            else:
                env[var] = orig
    return env


def build_helper_script(root, new_root, pid, platform=None):
    """Script that waits for the running app to exit, swaps the folders, relaunches and removes itself."""
    key = platform_key(platform)
    root, new_root = Path(root), Path(new_root)
    old = root.with_name(root.name + ".old")
    exe = root / inner_exe(platform)
    if key == "windows":
        return "\r\n".join([
            "@echo off",
            r'set "LOG=%TEMP%\ShuffleDetector-update.log"',  # kept so a failed swap can be diagnosed
            f'echo %date% %time% update started, waiting for PID {int(pid)} > "%LOG%"',
            "set n=0",
            ":waitpid",
            rf'"%SystemRoot%\System32\tasklist.exe" /FI "PID eq {int(pid)}" /FO LIST 2>nul | "%SystemRoot%\System32\find.exe" "PID:" >nul',
            "if errorlevel 1 goto swap",
            "set /a n+=1",
            "if %n% geq 120 goto swap",
            "ping -n 2 127.0.0.1 >nul",
            "goto waitpid",
            ":swap",
            f'echo %date% %time% PID wait over after %n% checks, moving the app folder {LOG_REDIRECT}',
            "set n=0",
            ":retry",
            f'move "{root}" "{old}" {LOG_REDIRECT}',
            "if not errorlevel 1 goto swapped",
            "set /a n+=1",
            "if %n% geq 30 goto fail",  # about 30 s: enough for antivirus to let go, short enough not to look like a stray launch
            "ping -n 2 127.0.0.1 >nul",
            "goto retry",
            ":swapped",
            f'move "{new_root}" "{root}" {LOG_REDIRECT}',
            f'if errorlevel 1 (move "{old}" "{root}" {LOG_REDIRECT}) else (rmdir /s /q "{old}")',
            f'echo %date% %time% swap finished {LOG_REDIRECT}',
            "goto launch",
            ":fail",
            f'echo %date% %time% could not move the app folder, keeping the current version {LOG_REDIRECT}',
            f'rmdir /s /q "{new_root}"',
            ":launch",
            f'start "" "{exe}"',
            '(goto) 2>nul & del "%~f0"',
            "",
        ])
    q = shlex.quote
    launch = f"open {q(str(root))}" if key == "macos" else f"nohup {q(str(exe))} >/dev/null 2>&1 &"
    return "\n".join([
        "#!/bin/sh",
        "n=0",
        f"while kill -0 {int(pid)} 2>/dev/null && [ $n -lt 240 ]; do sleep 0.5; n=$((n+1)); done",
        f"if mv {q(str(root))} {q(str(old))}; then",
        f"  if mv {q(str(new_root))} {q(str(root))}; then rm -rf {q(str(old))}; else mv {q(str(old))} {q(str(root))}; fi",
        "else",
        f"  rm -rf {q(str(new_root))}",
        "fi",
        launch,
        'rm -f "$0"',
        "",
    ])


def apply_update(new_root, root=None, platform=None):
    """Start the swap script detached. The caller must quit the application right afterwards."""
    key = platform_key(platform)
    root = Path(root) if root else app_root(platform=platform)
    script = Path(tempfile.mkdtemp(prefix="sd-update-")) / ("update.cmd" if key == "windows" else "update.sh")
    script.write_text(build_helper_script(root, new_root, os.getpid(), platform), newline="")
    # The helper must not run inside the app folder: a working directory there blocks renaming it (Explorer
    # starts the app with its own folder as the working directory).
    cwd = tempfile.gettempdir()
    if key == "windows":
        subprocess.Popen(["cmd", "/c", str(script)], cwd=cwd, env=clean_environment(platform=platform), close_fds=True,
                         creationflags=0x08000000 | 0x00000200)  # CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
    else:
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        subprocess.Popen(["/bin/sh", str(script)], cwd=cwd, env=clean_environment(platform=platform), close_fds=True,
                         start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
