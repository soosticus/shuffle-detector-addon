"""Reload source-checkout modules without replacing the QApplication or process."""

import importlib
import sys
from types import ModuleType
from pathlib import Path


MODULES = (
    "shuffledetector", "shuffledetector.luaparse", "shuffledetector.auctionator",
    "shuffledetector.deyields", "shuffledetector.casc", "shuffledetector.db2",
    "shuffledetector.addon_manager", "shuffledetector.calc", "shuffledetector.data_loader",
    "shuffledetector.calculator", "shuffledetector.localdata", "shuffledetector.plan",
    "shuffledetector.updater", "shuffledetector.releasenotes", "shuffledetector.selfupdate",
    "shuffledetector.gui", "shuffledetector.gui.live_reload", "shuffledetector.gui.app",
)


def disk_signature(root):
    paths = list((root / "companion/src/shuffledetector").rglob("*.py"))
    paths += list((root / "addon/ShuffleDetector").glob("*"))
    paths += list((root / "common/data").glob("*.json"))
    paths += list((root / "release-notes").glob("*.md"))
    paths.append(root / "companion/pyproject.toml")
    return tuple((str(p), p.stat().st_mtime_ns, p.stat().st_size) for p in sorted(paths) if p.is_file())


def reload_modules(build=None):
    modules = [importlib.import_module(name) for name in MODULES if name in sys.modules or name.endswith("gui.app")]
    # Compile before changing any module, and bypass stale timestamp-based bytecode caches.
    compiled = [(module, compile(Path(module.__file__).read_bytes(), module.__file__, "exec")) for module in modules]
    saved = [(module, dict(vars(module))) for module in modules]
    try:
        importlib.invalidate_caches()
        for module, code in compiled:
            metadata = {key: value for key, value in vars(module).items()
                        if (key.startswith("__") and key != "__builtins__") or isinstance(value, ModuleType)}
            vars(module).clear()
            vars(module).update(metadata)
            exec(code, vars(module))
        result = build(sys.modules["shuffledetector.gui.app"]) if build else sys.modules["shuffledetector.gui.app"]
    except Exception:
        for module, namespace in saved:
            vars(module).clear()
            vars(module).update(namespace)
        raise
    return result
