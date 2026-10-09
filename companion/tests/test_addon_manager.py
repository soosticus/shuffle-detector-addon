"""Tests for WoW discovery and addon install/update."""

import pytest

from shuffledetector import addon_manager as am


def make_addon(root, version):
    d = root / am.ADDON_NAME
    d.mkdir(parents=True)
    (d / f"{am.ADDON_NAME}.toc").write_text(f"## Title: X\n## Version: {version}\n\n{am.ADDON_NAME}.lua\n")
    (d / f"{am.ADDON_NAME}.lua").write_text(f"-- {version}\n")
    return d


@pytest.fixture
def wow(tmp_path, monkeypatch):
    bundle = tmp_path / "bundle"
    make_addon(bundle, "0.2.0")
    monkeypatch.setenv("SHUFFLEDETECTOR_ADDON", str(bundle / am.ADDON_NAME))
    monkeypatch.setattr(am, "default_roots", lambda: [])
    root = tmp_path / "World of Warcraft"
    (root / "_classic_" / "Interface" / "AddOns").mkdir(parents=True)
    (root / "_retail_" / "Interface" / "AddOns").mkdir(parents=True)
    (root / "Data").mkdir()
    return root


def test_parse_version():
    assert am.parse_version("0.10.2") == (0, 10, 2)
    assert am.parse_version("v1.2") == (1, 2)
    assert am.parse_version(None) is None
    assert am.parse_version("abc") is None


def test_discovery_root_flavor_and_addons_dir(wow):
    assert [i.flavor for i in am.installs_in(wow)] == ["_classic_", "_retail_"]
    assert [i.flavor for i in am.installs_in(wow / "_classic_")] == ["_classic_"]
    assert [i.flavor for i in am.installs_in(wow / "_retail_" / "Interface" / "AddOns")] == ["_retail_"]
    assert am.installs_in(wow / "missing") == []
    assert len(am.discover_installs([wow, wow])) == 2  # deduplicated


def test_install_then_update_preserves_nothing_stale(wow):
    inst = am.installs_in(wow / "_classic_")[0]
    assert am.status(inst) == "not_installed"
    assert am.install_addon(inst) == "0.2.0"
    assert am.status(inst) == "up_to_date"

    (inst.addon_dir / "stale.lua").write_text("old")
    (inst.addon_dir / f"{am.ADDON_NAME}.toc").write_text("## Version: 0.1.0\n")
    assert am.status(inst) == "outdated"
    am.install_addon(inst)
    assert am.status(inst) == "up_to_date"
    assert not (inst.addon_dir / "stale.lua").exists()
    assert not list(inst.addons_dir.glob(".*"))  # temp dirs cleaned


def test_newer_installed_is_not_downgraded_status(wow):
    inst = am.installs_in(wow / "_classic_")[0]
    make_addon(inst.addons_dir, "9.0.0")
    assert am.status(inst) == "newer"


def test_no_bundle(wow, monkeypatch):
    monkeypatch.setenv("SHUFFLEDETECTOR_ADDON", str(wow / "nope"))
    monkeypatch.setattr(am, "_BUNDLED_ADDON", wow / "nope1")
    monkeypatch.setattr(am, "_REPO_ADDON", wow / "nope2")
    inst = am.installs_in(wow / "_classic_")[0]
    assert am.status(inst) == "no_bundle"
    with pytest.raises(FileNotFoundError):
        am.install_addon(inst)
