"""Validate permitted reference inputs and generate a deterministic, client-specific Lua bundle.

Permission and verification fields record reviewed evidence; the generator cannot establish
legal rights or game accuracy. No production source or disenchant baseline is supplied here.
"""

import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile

from .plan import lua_string

SCHEMA_VERSION = 1
MAX_EXACT_INTEGER = 2 ** 53 - 1


class BundleError(ValueError):
    pass


def _require(ok, where, message):
    if not ok:
        raise BundleError(f"{where}: {message}")


def _object(value, required, optional, where):
    _require(isinstance(value, dict), where, "expected an object")
    _require(set(required) <= value.keys(), where, f"required fields: {', '.join(sorted(required))}")
    _require(value.keys() <= set(required) | set(optional), where, "unrecognized fields")


def _text(value, where):
    _require(isinstance(value, str) and bool(value.strip()), where, "expected nonempty text")


def _integer(value, where):
    _require(type(value) is int and 0 < value <= MAX_EXACT_INTEGER,
             where, "expected a positive integer exactly representable in Lua")


def _positive(value, where):
    _require(type(value) in (int, float) and 0 < value <= MAX_EXACT_INTEGER and math.isfinite(value),
             where, "expected a finite positive number")


def _rows(value, where):
    _require(isinstance(value, list), where, "expected an array")
    return enumerate(value)


def _unique(values, where):
    _require(len(values) == len(set(values)), where, "duplicate identities")


def _materials(rows, quantity, where, allow_empty=False):
    for i, row in _rows(rows, where):
        path = f"{where}[{i}]"
        _object(row, {"item", quantity}, set(), path)
        _integer(row["item"], path + ".item")
        (_integer if quantity == "qty" else _positive)(row[quantity], path + "." + quantity)
    _require(allow_empty or bool(rows), where, "empty data is unknown, not a zero-yield model")
    _unique([row["item"] for row in rows], where)
    rows.sort(key=lambda row: row["item"])


def _record(row, required, optional, sources, where):
    _object(row, set(required) | {"source", "status"}, set(optional) | {"verification"}, where)
    _text(row["source"], where + ".source")
    _require(row["source"] in sources, where, "unknown source")
    _require(row["status"] in ("trusted", "exploratory"), where, "invalid status")
    if "verification" in row:
        _text(row["verification"], where + ".verification")
    if row["status"] == "trusted":
        _require("verification" in row, where, "trusted data requires client-verification evidence")


def prepare_bundle(raw):
    """Validate and canonicalize without mutating input. Absent models remain absent."""
    data = copy.deepcopy(raw)
    _object(data, {"schema", "revision", "client", "coverage", "sources", "recipes", "disenchant", "exclusions"},
            set(), "bundle")
    _require(type(data["schema"]) is int and data["schema"] == SCHEMA_VERSION, "schema", "unsupported version")
    _text(data["revision"], "revision")
    _text(data["coverage"], "coverage")
    client = data["client"]
    _object(client, {"flavor", "interface", "build"}, set(), "client")
    _text(client["flavor"], "client.flavor")
    _text(client["build"], "client.build")
    _integer(client["interface"], "client.interface")

    for i, source in _rows(data["sources"], "sources"):
        path = f"sources[{i}]"
        _object(source, {"id", "revision", "sha256", "license", "permission", "redistributable"}, set(), path)
        for key in ("id", "revision", "sha256", "license", "permission"):
            _text(source[key], path + "." + key)
        _require(re.fullmatch(r"[0-9a-f]{64}", source["sha256"]) is not None, path, "invalid SHA256")
        _require(source["redistributable"] is True, path, "redistribution must be explicitly permitted")
    _unique([s["id"] for s in data["sources"]], "sources")
    sources = {s["id"] for s in data["sources"]}
    data["sources"].sort(key=lambda s: s["id"])

    for i, row in _rows(data["recipes"], "recipes"):
        path = f"recipes[{i}]"
        _record(row, {"spell", "item", "profession", "makes", "reagents"},
                {"name", "skill", "craft_seconds"}, sources, path)
        for key in ("spell", "item", "profession", "makes"):
            _integer(row[key], path + "." + key)
        if "name" in row:
            _text(row["name"], path + ".name")
        if "skill" in row:
            _require(type(row["skill"]) is int and 0 <= row["skill"] <= MAX_EXACT_INTEGER,
                     path + ".skill", "invalid skill")
        if "craft_seconds" in row:
            _positive(row["craft_seconds"], path + ".craft_seconds")
        _materials(row["reagents"], "qty", path + ".reagents")
    _unique([(r["spell"], r["status"]) for r in data["recipes"]], "recipes")
    data["recipes"].sort(key=lambda r: (r["spell"], r["status"]))

    for i, row in _rows(data["disenchant"], "disenchant"):
        path = f"disenchant[{i}]"
        _record(row, {"class", "quality", "low", "high"}, {"expected", "outcomes"}, sources, path)
        for key in ("class", "quality", "low", "high"):
            _integer(row[key], path + "." + key)
        _require(row["class"] in (2, 4) and row["quality"] in (2, 3, 4), path, "unsupported class or quality")
        _require(row["low"] <= row["high"], path, "reversed level band")
        _require(("expected" in row) != ("outcomes" in row), path, "give expected values OR complete outcomes")
        if "expected" in row:
            _materials(row["expected"], "avg", path + ".expected")
        else:
            outcomes = row["outcomes"]
            for j, outcome in _rows(outcomes, path + ".outcomes"):
                opath = f"{path}.outcomes[{j}]"
                _object(outcome, {"probability", "loot"}, set(), opath)
                _positive(outcome["probability"], opath + ".probability")
                _require(outcome["probability"] <= 1, opath, "probability exceeds one")
                _materials(outcome["loot"], "qty", opath + ".loot", allow_empty=True)
            _require(bool(outcomes) and math.isclose(sum(o["probability"] for o in outcomes), 1,
                                                   rel_tol=0, abs_tol=1e-9),
                     path, "outcome probabilities must sum to one; no automatic normalization")
            _require(any(o["loot"] for o in outcomes), path, "no material outcomes")
            keys = [tuple((m["item"], m["qty"]) for m in o["loot"]) for o in outcomes]
            _unique(keys, path + ".outcomes")
            outcomes.sort(key=lambda o: tuple((m["item"], m["qty"]) for m in o["loot"]))
    data["disenchant"].sort(key=lambda r: (r["class"], r["quality"], r["status"], r["low"]))
    previous = {}
    for row in data["disenchant"]:
        key = row["class"], row["quality"], row["status"]
        _require(row["low"] > previous.get(key, 0), "disenchant", "overlapping inclusive level bands")
        previous[key] = row["high"]

    for i, row in _rows(data["exclusions"], "exclusions"):
        path = f"exclusions[{i}]"
        _record(row, {"item", "reason"}, set(), sources, path)
        _integer(row["item"], path + ".item")
        _text(row["reason"], path + ".reason")
    _unique([(r["item"], r["status"]) for r in data["exclusions"]], "exclusions")
    data["exclusions"].sort(key=lambda r: (r["item"], r["status"]))
    return data


def wanted_items(data):
    """Item-cache requests derived from validated bundle rows, not a desktop export."""
    ids = {r["item"] for r in data["recipes"]} | {r["item"] for r in data["exclusions"]}
    for recipe in data["recipes"]:
        ids.update(m["item"] for m in recipe["reagents"])
    for model in data["disenchant"]:
        ids.update(m["item"] for m in model.get("expected", []))
        for outcome in model.get("outcomes", []):
            ids.update(m["item"] for m in outcome["loot"])
    return sorted(ids)


def _lua(value):
    if isinstance(value, dict):
        return "{ " + ", ".join(f"[{lua_string(k)}] = {_lua(v)}" for k, v in sorted(value.items())) + " }"
    if isinstance(value, list):
        return "{ " + ", ".join(_lua(v) for v in value) + " }"
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, bool):
        return "true" if value else "false"
    return repr(value)


def render_bundle(raw):
    data = prepare_bundle(raw)
    canonical = json.dumps(data, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    data["content_sha256"] = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    data["wanted_items"] = wanted_items(data)
    return "-- Generated reference bundle; do not edit.\nlocal _, ns = ...\nns.bundle = " + _lua(data) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="reviewed bundle input JSON")
    parser.add_argument("output", type=Path, help="generated Lua file (parent directory must exist)")
    args = parser.parse_args(argv)
    temporary = None
    try:
        text = render_bundle(json.loads(args.source.read_text(encoding="utf-8")))
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                         dir=args.output.parent, delete=False) as out:
            temporary = Path(out.name)
            out.write(text)
        os.replace(temporary, args.output)
    except (OSError, ValueError) as err:
        parser.error(str(err))
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
