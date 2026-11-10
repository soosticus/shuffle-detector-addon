"""Synthetic contract fixtures, not a distributable game-data baseline."""

import copy
import json
import shutil
import subprocess

import pytest

from shuffledetector import bundle


def sample():
    return {
        "schema": 1, "revision": "synthetic-test", "coverage": "Synthetic rows only; not game data.",
        "client": {"flavor": "test-client", "build": "test-build", "interface": 16001},
        "sources": [{"id": "test", "revision": "fixture", "sha256": "a" * 64,
                     "license": "MIT", "permission": "Synthetic test data authored here", "redistributable": True}],
        "recipes": [{"spell": 10, "item": 20, "profession": 197, "makes": 2,
                     "reagents": [{"item": 2, "qty": 3}, {"item": 1, "qty": 2}],
                     "source": "test", "status": "trusted", "verification": "Synthetic fixture assertion"}],
        "disenchant": [{"class": 4, "quality": 2, "low": 1, "high": 10, "source": "test",
                       "status": "trusted", "verification": "Synthetic fixture assertion",
                       "outcomes": [{"probability": 0.75, "loot": [{"item": 30, "qty": 2}]},
                                    {"probability": 0.25, "loot": [{"item": 40, "qty": 1}]}]}],
        "exclusions": [],
    }


def test_deterministic_generation_preserves_input_and_exact_outcomes(tmp_path):
    raw = sample()
    original = copy.deepcopy(raw)
    first = bundle.render_bundle(raw)
    assert raw == original
    raw["recipes"][0]["reagents"].reverse()
    raw["disenchant"][0]["outcomes"].reverse()
    assert bundle.render_bundle(raw) == first
    lua = shutil.which("lua5.1") or shutil.which("lua")
    if not lua:
        pytest.skip("Lua is required to exercise the generated bundle")
    output = tmp_path / "Data.lua"
    output.write_text(first, encoding="utf-8")
    check = subprocess.run([lua, "-", str(output)], input="""
        local ns = {}
        assert(loadfile(arg[1]))("ShuffleDetector", ns)
        assert(ns.bundle.schema == 1 and #ns.bundle.content_sha256 == 64)
        assert(table.concat(ns.bundle.wanted_items, ",") == "1,2,20,30,40")
        assert(#ns.bundle.disenchant[1].outcomes == 2)
        assert(ns.bundle.disenchant[1].outcomes[1].loot[1].item == 30)
        assert(ns.bundle.disenchant[1].outcomes[1].probability == 0.75)
    """, capture_output=True, text=True)
    assert check.returncode == 0, check.stdout + check.stderr


@pytest.mark.parametrize("change, message", [
    (lambda d: d["sources"][0].update(redistributable=False), "redistribution"),
    (lambda d: d["sources"][0].update(permission=""), "nonempty"),
    (lambda d: d["sources"][0].update(sha256="not-a-hash"), "SHA256"),
    (lambda d: d["recipes"][0].update(source="missing"), "unknown source"),
    (lambda d: d["disenchant"][0].pop("verification"), "verification"),
    (lambda d: d["client"].pop("build"), "required fields"),
    (lambda d: d.update(schema=2), "unsupported version"),
    (lambda d: d.update(schema=True), "unsupported version"),
    (lambda d: d["recipes"][0].update(makes=True), "positive integer"),
    (lambda d: d["recipes"][0].update(item=2 ** 53), "exactly representable"),
    (lambda d: d["recipes"][0]["reagents"][0].update(qty=0), "positive integer"),
    (lambda d: d["disenchant"][0].update(low=11), "reversed"),
    (lambda d: d["disenchant"][0]["outcomes"][0].update(probability=0.6), "sum to one"),
    (lambda d: d["disenchant"][0]["outcomes"][0].update(probability=float("nan")), "finite positive"),
    (lambda d: d["recipes"][0]["reagents"].append({"item": 1, "qty": 1}), "duplicate"),
])
def test_invalid_or_unreviewed_data_fails_closed(change, message):
    raw = sample()
    change(raw)
    with pytest.raises(bundle.BundleError, match=message):
        bundle.render_bundle(raw)


def test_inclusive_bands_cannot_overlap_within_the_same_trust_level():
    raw = sample()
    other = copy.deepcopy(raw["disenchant"][0])
    other.update(low=10, high=20)
    raw["disenchant"].append(other)
    with pytest.raises(bundle.BundleError, match="overlapping"):
        bundle.prepare_bundle(raw)
    other["low"] = 11
    assert len(bundle.prepare_bundle(raw)["disenchant"]) == 2
    other.update(low=1, status="exploratory")
    assert len(bundle.prepare_bundle(raw)["disenchant"]) == 2


def test_expectation_only_models_do_not_gain_invented_outcomes_or_ranges():
    raw = sample()
    model = raw["disenchant"][0]
    del model["outcomes"]
    model.update(status="exploratory", expected=[{"item": 30, "avg": 0.8}])
    del model["verification"]
    prepared = bundle.prepare_bundle(raw)
    assert prepared["disenchant"][0] == model
    for invalid in (0, -1, float("inf"), 10 ** 400):
        model["expected"][0]["avg"] = invalid
        with pytest.raises(bundle.BundleError, match="finite positive"):
            bundle.prepare_bundle(raw)
    model["expected"] = []
    with pytest.raises(bundle.BundleError, match="unknown"):
        bundle.prepare_bundle(raw)


def test_unknown_coverage_stays_absent_not_zero():
    raw = sample()
    raw.update(recipes=[], disenchant=[], sources=[])
    result = bundle.prepare_bundle(raw)
    assert result["disenchant"] == []
    assert bundle.wanted_items(result) == []


def test_cli_preserves_existing_output_when_validation_fails(tmp_path):
    source, output = tmp_path / "input.json", tmp_path / "Data.lua"
    raw = sample()
    source.write_text(json.dumps(raw))
    bundle.main([str(source), str(output)])
    original = output.read_bytes()
    raw["sources"][0]["redistributable"] = False
    source.write_text(json.dumps(raw))
    with pytest.raises(SystemExit) as exc:
        bundle.main([str(source), str(output)])
    assert exc.value.code == 2
    assert output.read_bytes() == original
    assert sorted(p.name for p in tmp_path.iterdir()) == ["Data.lua", "input.json"]
