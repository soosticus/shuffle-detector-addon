"""Read files from a local CASC install (the game's own Data folder), by FileDataID."""

import bisect
import glob
import os
import re
import struct
import zlib
from pathlib import Path


class CascError(Exception):
    pass


def find_install_root(start):
    """Walk up from `start` to the folder holding .build.info and Data/."""
    p = Path(start).resolve()
    for cand in [p, *p.parents]:
        if (cand / ".build.info").is_file() and (cand / "Data").is_dir():
            return cand
    return None


def parse_build_info(root, product=None):
    """Return the active .build.info row as a dict (optionally for one product)."""
    lines = (Path(root) / ".build.info").read_text(encoding="utf-8", errors="replace").splitlines()
    cols = [c.split("!")[0] for c in lines[0].split("|")]
    rows = [dict(zip(cols, ln.split("|"))) for ln in lines[1:] if ln.strip()]
    rows = [r for r in rows if not product or r.get("Product") == product]
    rows.sort(key=lambda r: r.get("Active") != "1")
    if not rows:
        raise CascError("no matching entry in .build.info")
    return rows[0]


def _parse_config(path):
    out = {}
    for ln in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^([\w-]+)\s*=\s*(.*)$", ln)
        if m:
            out[m.group(1)] = m.group(2).split()
    return out


def _load_index(data_dir):
    best = {}
    for f in glob.glob(os.path.join(data_dir, "data", "*.idx")):
        n = os.path.basename(f)
        bucket, ver = int(n[:2], 16), int(n[2:10], 16)
        if bucket not in best or ver > best[bucket][0]:
            best[bucket] = (ver, f)
    idx = {}
    for _, f in best.values():
        b = Path(f).read_bytes()
        if struct.unpack_from("<H", b, 8)[0] != 7:
            raise CascError("unsupported idx version")
        esize = struct.unpack_from("<I", b, 0x20)[0]
        p = 0x28
        for _i in range(esize // 18):
            key = b[p:p + 9]
            off5 = int.from_bytes(b[p + 9:p + 14], "big")
            size = struct.unpack_from("<I", b, p + 14)[0]
            idx[key] = (off5 >> 30, off5 & 0x3FFFFFFF, size)
            p += 18
    return idx


def blte_decode(buf):
    """Decode BLTE; encrypted blocks yield b'' (they only cover small trailing sections)."""
    if buf[:4] != b"BLTE":
        raise CascError("not BLTE data")
    hsize = struct.unpack_from(">I", buf, 4)[0]
    if hsize == 0:
        chunks, pos = [len(buf) - 8], 8
    else:
        cnt = int.from_bytes(buf[9:12], "big")
        chunks = [struct.unpack_from(">I", buf, 12 + i * 24)[0] for i in range(cnt)]
        pos = hsize
    out = []
    for cs in chunks:
        blk = buf[pos:pos + cs]
        pos += cs
        t = blk[:1]
        if t == b"N":
            out.append(blk[1:])
        elif t == b"Z":
            out.append(zlib.decompress(blk[1:]))
        elif t == b"E":
            out.append(b"")
        else:
            raise CascError("unsupported BLTE block type %r" % t)
    return b"".join(out)


class Casc:
    """Resolve FileDataID -> content key (root) -> encoded key (encoding) -> bytes (data archives)."""

    def __init__(self, install_root, product=None):
        self.root_dir = Path(install_root)
        self.data_dir = self.root_dir / "Data"
        info = parse_build_info(self.root_dir, product)
        self.version = info.get("Version", "")
        key = info["Build Key"]
        cfg = _parse_config(self.data_dir / "config" / key[:2] / key[2:4] / key)
        self.idx = _load_index(str(self.data_dir))
        self._fh = {}
        self._enc = self._read_ekey(bytes.fromhex(cfg["encoding"][1]))
        self._init_encoding()
        self._fd2ck = self._parse_root(self._read_ckey(bytes.fromhex(cfg["root"][0])))

    def close(self):
        for fh in self._fh.values():
            fh.close()
        self._fh.clear()

    def _read_ekey(self, ekey):
        try:
            arch, off, size = self.idx[bytes(ekey[:9])]
        except KeyError:
            raise CascError("encoded key not in local storage")
        fh = self._fh.get(arch)
        if fh is None:
            fh = self._fh[arch] = open(self.data_dir / "data" / ("data.%03d" % arch), "rb")
        fh.seek(off)
        raw = fh.read(size)
        return blte_decode(raw if raw[:4] == b"BLTE" else raw[0x1E:])

    def _init_encoding(self):
        e = self._enc
        if e[:2] != b"EN":
            raise CascError("bad encoding file")
        cps_kb, = struct.unpack_from(">H", e, 5)
        self._page = cps_kb * 1024
        self._ccount, = struct.unpack_from(">I", e, 9)
        espec, = struct.unpack_from(">I", e, 18)
        idx_start = 22 + espec
        self._pages_start = idx_start + self._ccount * 32
        self._first = [e[idx_start + i * 32:idx_start + i * 32 + 16] for i in range(self._ccount)]

    def _ekeys_for(self, ckey):
        i = bisect.bisect_right(self._first, ckey) - 1
        if i < 0:
            return []
        p = self._pages_start + i * self._page
        end = p + self._page
        e = self._enc
        while p < end and e[p]:
            n = e[p]
            if e[p + 6:p + 22] == ckey:
                return [e[p + 22 + 16 * k:p + 38 + 16 * k] for k in range(n)]
            p += 22 + 16 * n
        return []

    def _read_ckey(self, ckey):
        for ek in self._ekeys_for(ckey):
            if ek[:9] in self.idx:
                return self._read_ekey(ek)
        raise CascError("content key not in local storage")

    @staticmethod
    def _parse_root(root):
        if root[:4] not in (b"TSFM", b"MFST"):
            raise CascError("unsupported root format")
        pos = 24
        out = {}
        while pos < len(root):
            n, _loc, u1, u2, u3 = struct.unpack_from("<IIIIB", root, pos)
            pos += 17
            cflags = u1 | u2 | (u3 << 17)
            fds, cur = [], -1
            for _i in range(n):
                cur += struct.unpack_from("<i", root, pos)[0] + 1
                pos += 4
                fds.append(cur)
            cks = [root[pos + i * 16:pos + i * 16 + 16] for i in range(n)]
            pos += 16 * n
            if not cflags & 0x10000000:
                pos += 8 * n
            for f, ck in zip(fds, cks):
                out.setdefault(f, []).append(ck)  # one per locale variant
        return out

    def read_fdid(self, fdid):
        """Bytes of the file, taking the first locale variant present on this machine."""
        for ck in self._fd2ck.get(fdid, []):
            for ek in self._ekeys_for(ck):
                if ek[:9] in self.idx:
                    return self._read_ekey(ek)
        raise CascError("FileDataID %d not in local storage" % fdid)
