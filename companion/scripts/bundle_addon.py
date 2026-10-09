"""Copy addon/ShuffleDetector into the package so built wheels/executables bundle it.

Run before `pip wheel` / PyInstaller.
"""

import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[2]
src = root / "addon" / "ShuffleDetector"
dst = root / "companion" / "src" / "shuffledetector" / "_addon" / "ShuffleDetector"
shutil.rmtree(dst.parent, ignore_errors=True)
shutil.copytree(src, dst)
print(f"Bundled {src} -> {dst}")
