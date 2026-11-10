"""Run the addon's shopping logic against a deterministic WoW API stub."""

import shutil
import subprocess
from pathlib import Path

import pytest


@pytest.mark.parametrize("harness, marker", [
    ("snatch_harness.lua", "snatcher checks passed"),
    ("disenchant_harness.lua", "disenchant checks passed"),
])
def test_addon_lua_harness(harness, marker):
    lua = shutil.which("lua")
    if not lua:
        pytest.skip("Lua is required for the addon API harness")
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [lua, str(Path(__file__).with_name(harness))],
        cwd=root, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert marker in result.stdout
