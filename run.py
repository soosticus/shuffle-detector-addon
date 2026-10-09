#!/usr/bin/env python3
"""Run the ShuffleDetector companion from the source tree.

    python run.py              launch the GUI
    python run.py --cli ARGS   run the command-line interface
    python run.py --test       run the test suite
    python run.py --setup      only create/refresh the virtualenv

The first run creates .venv and installs the companion (editable) with GUI dependencies;
it re-installs automatically when companion/pyproject.toml changes.
"""

import hashlib
import subprocess
import sys
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent
COMPANION = ROOT / "companion"
VENV = ROOT / ".venv"
STAMP = VENV / ".install-stamp"


def venv_python():
    return VENV / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")


def pyproject_hash():
    return hashlib.sha256((COMPANION / "pyproject.toml").read_bytes()).hexdigest()


def ensure_env():
    py = venv_python()
    if not py.exists():
        print("Creating virtualenv in .venv ...", flush=True)
        venv.EnvBuilder(with_pip=True).create(VENV)
    want = pyproject_hash()
    if not STAMP.exists() or STAMP.read_text() != want:
        print("Installing dependencies (first run may take a minute) ...", flush=True)
        cmd = [str(py), "-m", "pip", "install", "--quiet", "--disable-pip-version-check", "-e", f"{COMPANION}[gui,dev]"]
        if subprocess.call(cmd) != 0:
            sys.exit("Dependency install failed.")
        STAMP.write_text(want)
    return py


def main(argv):
    if sys.version_info < (3, 9):
        sys.exit("Python 3.9 or newer is required.")
    mode, rest = "gui", argv
    if argv[:1] in (["--cli"], ["--test"], ["--setup"]):
        mode, rest = argv[0][2:], argv[1:]
    py = ensure_env()
    if mode == "setup":
        return 0
    if mode == "cli":
        cmd = [str(py), "-m", "shuffledetector.cli", *rest]
    elif mode == "test":
        cmd = [str(py), "-m", "pytest", str(COMPANION), *rest]
    else:
        cmd = [str(py), "-m", "shuffledetector.gui.app", *rest]
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
