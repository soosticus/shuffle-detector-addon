"""Minimal parser for WoW SavedVariables files (Lua table assignments)."""

import re

_TOKEN = re.compile(
    r"""
    (?P<ws>\s+|--[^\n]*)
  | (?P<num>-?(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?))
  | (?P<str>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')
  | (?P<name>[A-Za-z_][A-Za-z_0-9]*)
  | (?P<sym>[{}\[\]=,;])
    """,
    re.VERBOSE,
)

_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


class LuaParseError(ValueError):
    pass


def _unescape(raw):
    body = raw[1:-1]
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt.isdigit():
                j = i + 1
                while j < len(body) and j < i + 4 and body[j].isdigit():
                    j += 1
                out.append(chr(int(body[i + 1:j])))
                i = j
                continue
            out.append(_ESCAPES.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _tokenize(text):
    pos, tokens = 0, []
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise LuaParseError(f"unexpected character {text[pos]!r} at offset {pos}")
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        tokens.append((kind, m.group()))
    return tokens


class _Parser:
    def __init__(self, tokens):
        self.t = tokens
        self.i = 0

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self):
        tok = self.peek()
        self.i += 1
        return tok

    def expect(self, sym):
        kind, val = self.take()
        if kind != "sym" or val != sym:
            raise LuaParseError(f"expected {sym!r}, got {val!r}")

    def parse_file(self):
        result = {}
        while self.peek()[0] is not None:
            kind, name = self.take()
            if kind != "name":
                raise LuaParseError(f"expected variable name, got {name!r}")
            self.expect("=")
            result[name] = self.parse_value()
            if self.peek() == ("sym", ";"):
                self.take()
        return result

    def parse_value(self):
        kind, val = self.take()
        if kind == "num":
            if val.lower().lstrip("-").startswith("0x"):
                return int(val, 16)
            f = float(val)
            return int(f) if f.is_integer() and not re.search(r"[.eE]", val) else f
        if kind == "str":
            return _unescape(val)
        if kind == "name":
            if val == "true":
                return True
            if val == "false":
                return False
            if val == "nil":
                return None
            raise LuaParseError(f"unsupported identifier {val!r}")
        if kind == "sym" and val == "{":
            return self.parse_table()
        raise LuaParseError(f"unexpected token {val!r}")

    def parse_table(self):
        entries, auto = [], 1
        while True:
            kind, val = self.peek()
            if kind == "sym" and val == "}":
                self.take()
                break
            if kind == "sym" and val == "[":
                self.take()
                key = self.parse_value()
                self.expect("]")
                self.expect("=")
                entries.append((key, self.parse_value()))
            elif kind == "name" and self.i + 1 < len(self.t) and self.t[self.i + 1] == ("sym", "="):
                self.take()
                self.take()
                entries.append((val, self.parse_value()))
            else:
                entries.append((auto, self.parse_value()))
                auto += 1
            kind, val = self.peek()
            if kind == "sym" and val in ",;":
                self.take()
        keys = [k for k, _ in entries]
        if keys and keys == list(range(1, len(keys) + 1)):
            return [v for _, v in entries]
        return {k: v for k, v in entries if v is not None}


def parse(text):
    """Parse a SavedVariables file into {variable_name: value}."""
    return _Parser(_tokenize(text)).parse_file()


def load(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return parse(fh.read())
