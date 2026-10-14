"""Builds an Auctionator.lua SavedVariables file the way the game writes it (one CBOR blob per realm)."""

from datetime import datetime

DAY_ZERO = datetime(2020, 1, 1).timestamp()


def _head(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    if n < 256:
        return bytes([major << 5 | 24, n])
    if n < 65536:
        return bytes([major << 5 | 25]) + n.to_bytes(2, "big")
    return bytes([major << 5 | 26]) + n.to_bytes(4, "big")


def cbor(value):
    if isinstance(value, bool) or value is None or isinstance(value, float):
        raise TypeError("not needed by the fixture")
    if isinstance(value, int):
        return _head(0, value)
    if isinstance(value, str):
        raw = value.encode("latin-1")
        return _head(2, len(raw)) + raw
    if isinstance(value, dict):
        return _head(5, len(value)) + b"".join(cbor(k) + cbor(v) for k, v in value.items())
    if isinstance(value, list):
        return _head(4, len(value)) + b"".join(cbor(v) for v in value)
    raise TypeError(type(value))


def lua_string(raw):
    return '"' + "".join("\\%03d" % b for b in raw) + '"'


def entry(price, day):
    return {"m": price, "h": {str(day): price}, "l": {}, "a": {str(day): 5}}


def write(directory, realms, version=8):
    """`realms` maps realm key -> {db key: entry dict}; returns the path of the file written."""
    lines = ["AUCTIONATOR_PRICE_DATABASE = {", f'["__dbversion"] = {version},']
    for realm, db in realms.items():
        blob = db if isinstance(db, bytes) else cbor(db)
        lines.append(f'["{realm}"] = {lua_string(blob)},')
    lines.append("}")
    path = directory / "Auctionator.lua"
    path.write_text("\n".join(lines), encoding="latin-1")
    return path
