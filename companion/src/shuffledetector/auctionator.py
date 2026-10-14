"""Reads Auctionator's price database straight from its SavedVariables file.

Auctionator keeps one CBOR blob per realm in AUCTIONATOR_PRICE_DATABASE; each item maps to
{"m": last seen minimum price, "h": {day: highest low}, "l": {day: lowest low}, "a": {day: quantity}}.
Days are counted from 2020-01-01 local midnight. Auctionator keeps minimum prices only, so the
result is "shallow": the calculator assumes any quantity is buyable at that price.
"""

import re
import struct
from datetime import datetime
from pathlib import Path

from . import luaparse

SAVED_VARIABLES_FILE = "Auctionator.lua"
VARIABLE = "AUCTIONATOR_PRICE_DATABASE"
UNLIMITED_QTY = 10 ** 9


class CborError(ValueError):
    pass


def decode_cbor(data):
    """Decode one CBOR value from `data` (bytes). Byte strings come back as latin-1 `str`."""
    value, end = _decode(data, 0)
    if end != len(data):
        raise CborError("trailing data after the CBOR value")
    return value


def _argument(data, pos, info):
    if info < 24:
        return info, pos
    size = {24: 1, 25: 2, 26: 4, 27: 8}.get(info)
    if size is None or pos + size > len(data):
        raise CborError("unsupported or truncated length")
    return int.from_bytes(data[pos:pos + size], "big"), pos + size


def _decode(data, pos):
    if pos >= len(data):
        raise CborError("unexpected end of data")
    major, info = data[pos] >> 5, data[pos] & 0x1F
    pos += 1
    if major == 7:
        if info == 20:
            return False, pos
        if info == 21:
            return True, pos
        if info == 22 or info == 23:
            return None, pos
        if info == 25:
            return struct.unpack(">e", data[pos:pos + 2])[0], pos + 2
        if info == 26:
            return struct.unpack(">f", data[pos:pos + 4])[0], pos + 4
        if info == 27:
            return struct.unpack(">d", data[pos:pos + 8])[0], pos + 8
        raise CborError(f"unsupported simple value {info}")
    arg, pos = _argument(data, pos, info)
    if major == 0:
        return arg, pos
    if major == 1:
        return -1 - arg, pos
    if major in (2, 3):
        if pos + arg > len(data):
            raise CborError("truncated string")
        return data[pos:pos + arg].decode("latin-1"), pos + arg
    if major == 4:
        out = []
        for _ in range(arg):
            value, pos = _decode(data, pos)
            out.append(value)
        return out, pos
    if major == 5:
        out = {}
        for _ in range(arg):
            key, pos = _decode(data, pos)
            out[key], pos = _decode(data, pos)
        return out, pos
    return _decode(data, pos)  # major 6: a tag, keep the tagged value


def find_saved_variables(shuffledetector_path):
    """Auctionator's SavedVariables file sits next to ShuffleDetector's."""
    return Path(shuffledetector_path).with_name(SAVED_VARIABLES_FILE)


def _day_zero():
    return datetime(2020, 1, 1).timestamp()


def _item_id(key):
    m = re.match(r"^(\d+)$", key) or re.match(r"^g:(\d+):", key)
    return int(m.group(1)) if m else None


def _realm_prices(blob):
    """One realm's blob -> (items, newest_day). Gear keys ("g:id:ilvl") collapse to the cheapest variant."""
    db = decode_cbor(blob.encode("latin-1"))
    items, newest = {}, None
    for key, entry in db.items():
        item_id = _item_id(str(key))
        price = entry.get("m") if isinstance(entry, dict) else None
        if item_id is None or not isinstance(price, int) or price <= 0:
            continue
        for day in (entry.get("h") or {}):
            try:
                day = int(day)
            except ValueError:
                continue
            if newest is None or day > newest:
                newest = day
        if item_id not in items or price < items[item_id]["min"]:
            items[item_id] = {"min": price, "qty": UNLIMITED_QTY, "prices": [(price, UNLIMITED_QTY)]}
    return items, newest


def load_prices(path):
    """Return ({realm: scan}, note) from an Auctionator SavedVariables file.

    Each scan has the shape the calculator uses: time, listings (item count), items, source, shallow.
    `note` explains why nothing was loaded, or is "" on success.
    """
    path = Path(path)
    if not path.is_file():
        return {}, f"Auctionator's saved data was not found next to ShuffleDetector's ({path.name}). Is Auctionator installed?"
    try:
        db = luaparse.parse(path.read_text(encoding="latin-1")).get(VARIABLE)
    except luaparse.LuaParseError as err:
        return {}, f"could not read {path.name}: {err}"
    if not isinstance(db, dict):
        return {}, "Auctionator has no price database yet. Scan the auction house with Auctionator, then /reload."
    zero, scans, failed = _day_zero(), {}, []
    for realm, blob in db.items():
        if not isinstance(blob, str):
            continue  # "__dbversion"
        try:
            items, newest = _realm_prices(blob)
        except (CborError, struct.error, ValueError, AttributeError) as err:
            failed.append(f"{realm}: {err}")
            continue
        if items:
            stamp = zero + newest * 86400 if newest is not None else path.stat().st_mtime
            scans[realm] = {"time": int(stamp), "listings": len(items), "items": items,
                            "source": "auctionator", "shallow": True}
    if scans:
        return scans, ""
    if failed:
        return {}, f"could not decode Auctionator's price database (format version {db.get('__dbversion')}): {failed[0]}"
    return {}, "Auctionator has no prices yet. Scan the auction house with Auctionator, then /reload."
