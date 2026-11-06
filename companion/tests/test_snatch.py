"""Run the addon's shopping logic against a deterministic WoW API stub."""

import shutil
import subprocess
from pathlib import Path

import pytest


def test_snatcher_lua_harness():
    lua = shutil.which("lua")
    if not lua:
        pytest.skip("Lua is required for the addon API harness")
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [lua, str(Path(__file__).with_name("snatch_harness.lua"))],
        cwd=root, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "snatcher checks passed" in result.stdout
