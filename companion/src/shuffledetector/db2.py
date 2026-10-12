"""Minimal WDC5 (DB2) reader: dense tables only, which covers the recipe tables we need."""

import struct


class Db2Error(Exception):
    pass


class Table:
    def __init__(self, data):
        b = self.b = data
        if b[:4] != b"WDC5":
            raise Db2Error("not a WDC5 table: %r" % b[:4])
        (self.record_count, self.field_count, self.record_size, _ss, _th, _lh, _mn, _mx, _loc) = struct.unpack_from("<9I", b, 136)
        self.flags, self.id_index = struct.unpack_from("<HH", b, 172)
        tfc, _bo, _lc, fsi_size, common_size, pallet_size, nsec = struct.unpack_from("<7I", b, 176)
        if self.flags & 1:
            raise Db2Error("sparse (offset map) tables are not supported")
        p = 204
        self.sections = [struct.unpack_from("<Q8I", b, p + 40 * i) for i in range(nsec)]
        p += 40 * nsec + tfc * 4
        fsi = [struct.unpack_from("<HHIIIII", b, p + 24 * i) for i in range(fsi_size // 24)]
        p += fsi_size
        pallet, common = b[p:p + pallet_size], b[p + pallet_size:p + pallet_size + common_size]
        po = co = 0
        self._fields = []
        for off, size, add, storage, c1, _c2, c3 in fsi:
            data_ = None
            if storage in (3, 4):
                data_ = pallet[po:po + add]
                po += add
            elif storage == 2:
                blob = common[co:co + add]
                co += add
                data_ = {struct.unpack_from("<I", blob, k)[0]: struct.unpack_from("<I", blob, k + 4)[0]
                         for k in range(0, len(blob), 8)}
            self._fields.append((off, size, storage, c1, c3, data_))
        self._rows = None

    def rows(self):
        """List of (id, fields, foreign_key). Array fields are tuples; string fields are raw offsets."""
        if self._rows is not None:
            return self._rows
        b, rsz = self.b, self.record_size
        out, by_id = [], {}
        total_bytes = sum(s[2] for s in self.sections) * rsz
        prev_recs = prev_str = 0
        for tact, foff, rcnt, ssz, _orec, idsz, relsz, omc, cpc in self.sections:
            gbase, gstr = prev_recs * rsz, prev_str
            prev_recs += rcnt
            prev_str += ssz
            if tact != 0:
                continue  # encrypted section: contents unavailable
            recs = foff
            q = foff + rcnt * rsz + ssz
            ids = list(struct.unpack_from("<%dI" % (idsz // 4), b, q)) if idsz else None
            q += idsz
            copies = [struct.unpack_from("<II", b, q + 8 * i) for i in range(cpc)]
            q += cpc * 8 + omc * 6
            fks = {}
            if relsz:
                n = struct.unpack_from("<I", b, q)[0]
                for i in range(n):
                    fk, ri = struct.unpack_from("<II", b, q + 12 + 8 * i)
                    fks[ri] = fk
            start = len(out)
            for r in range(rcnt):
                base = recs + r * rsz
                vals = []
                for off, size, storage, c1, c3, fdata in self._fields:
                    if storage == 0:
                        nb = size // 8 if size >= 8 else 1
                        v = int.from_bytes(b[base + off // 8:base + off // 8 + nb], "little")
                    elif storage == 2:
                        v = fdata.get(ids[r] if ids else vals[self.id_index], c1)
                    else:
                        chunk = int.from_bytes(b[base + off // 8:base + (off + size + 7) // 8 + 1], "little")
                        v = (chunk >> (off % 8)) & ((1 << size) - 1)
                        if storage == 5 and v & (1 << (size - 1)):
                            v -= 1 << size
                        elif storage == 3:
                            v = struct.unpack_from("<I", fdata, v * 4)[0]
                        elif storage == 4:
                            v = tuple(struct.unpack_from("<I", fdata, (v * c3 + k) * 4)[0] for k in range(c3))
                    vals.append(v)
                rid = ids[r] if ids else vals[self.id_index]
                anchor = foff + rcnt * rsz + gbase + r * rsz - total_bytes - gstr
                out.append((rid, vals, fks.get(r), anchor))
                by_id[rid] = out[-1]
            for new_id, orig in copies:
                src = by_id.get(orig)
                if src:
                    out.append((new_id, src[1], src[2], src[3]))
        self._rows = out
        return out

    def string_at(self, row, field_index):
        """Resolve a string field.

        Offsets are relative to the field's position in a layout where every section's records
        (encrypted ones too) precede the concatenated string tables.
        """
        _rid, vals, _fk, anchor = row
        off, _size, *_ = self._fields[field_index]
        pos = anchor + off // 8 + vals[field_index]
        end = self.b.index(b"\0", pos)
        return self.b[pos:end].decode("utf-8", "replace")
