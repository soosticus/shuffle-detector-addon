"""Tests for reading Auctionator's price database from its SavedVariables file."""

from auctionator_fixture import DAY_ZERO, cbor, entry, write

from shuffledetector import auctionator, calc


def test_decode_cbor_basic_types():
    assert auctionator.decode_cbor(bytes([0x18, 200])) == 200
    assert auctionator.decode_cbor(bytes([0x39, 0x01, 0xF3])) == -500
    assert auctionator.decode_cbor(bytes([0xFB]) + b"\x3f\xf8\x00\x00\x00\x00\x00\x00") == 1.5
    assert auctionator.decode_cbor(bytes([0xF5])) is True
    assert auctionator.decode_cbor(cbor({"m": 7, "a": [1, 2]})) == {"m": 7, "a": [1, 2]}
    assert auctionator.decode_cbor(bytes([0xC1, 0x05])) == 5  # a tag is ignored


def test_decode_cbor_rejects_truncated_data():
    for bad in (b"", bytes([0x44, 0x31]), bytes([0xA1, 0x41, 0x61])):
        try:
            auctionator.decode_cbor(bad)
        except auctionator.CborError:
            continue
        raise AssertionError(f"{bad!r} should not decode")


def test_load_prices_reads_realms_and_collapses_gear_variants(tmp_path):
    day = 2474
    sv = write(tmp_path, {
        "ClassicBetaPvE2": {
            "2997": entry(100, day), "g:7054:30": entry(900, day), "g:7054:35": entry(700, day - 1),
            "p:99": entry(5, day), "3000": entry(0, day), "bad": entry(1, day),
        },
        "Old": {"2997": entry(50, 10)},
    })
    scans, note = auctionator.load_prices(sv)
    assert note == "" and sorted(scans) == ["ClassicBetaPvE2", "Old"]
    s = scans["ClassicBetaPvE2"]
    assert s["source"] == "auctionator" and s["shallow"] and s["listings"] == 2
    assert sorted(s["items"]) == [2997, 7054]
    assert s["items"][7054]["min"] == 700
    assert s["time"] == int(DAY_ZERO + day * 86400)
    assert calc.buy_cost(s["items"][2997], 200) == 200 * 100


def test_load_prices_missing_or_empty(tmp_path):
    scans, note = auctionator.load_prices(tmp_path / "Auctionator.lua")
    assert scans == {} and "Is Auctionator installed" in note
    scans, note = auctionator.load_prices(write(tmp_path, {}))
    assert scans == {} and "no prices yet" in note


def test_load_prices_unreadable_blob_explains_itself(tmp_path):
    scans, note = auctionator.load_prices(write(tmp_path, {"R": b"\xa5\x41"}, version=99))
    assert scans == {} and "format version 99" in note


def test_find_saved_variables_is_next_to_ours(tmp_path):
    assert auctionator.find_saved_variables(tmp_path / "ShuffleDetector.lua") == tmp_path / "Auctionator.lua"
