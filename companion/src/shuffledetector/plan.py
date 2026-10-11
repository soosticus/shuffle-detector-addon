"""Export a chosen shuffle to the addon's Plan.lua so the in-game shuffle button knows what to run."""

import os
import time

PLAN_VERSION = 1


def build_plan(result, now=None):
    """Plan dict for a calc.Result: the recipe to craft, its reagents, and the exit step."""
    r = result.recipe
    plan = {
        "version": PLAN_VERSION,
        "generated": int(now if now is not None else time.time()),
        "recipe": r["name"],
        "exit": result.exit if result.exit and result.exit != "-" else "",
        "reagents": [{"item": x["item"], "qty": x["qty"]} for x in r.get("reagents", [])],
    }
    if r.get("spell"):
        plan["spell"] = r["spell"]
    if r.get("item"):
        plan["item"] = r["item"]
    if result.crafted and result.crafted.name:
        plan["itemName"] = result.crafted.name
    return plan


def lua_string(s):
    out = ['"']
    for ch in str(s):
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif o < 32 or o == 127:
            out.append(f"\\{o:03d}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(_lua_value(x) for x in v) + " }"
    if isinstance(v, dict):
        return "{ " + ", ".join(f"{k} = {_lua_value(x)}" for k, x in v.items()) + " }"
    return lua_string(v)


def render_plan(plan):
    lines = ["-- Written by the ShuffleDetector companion app. /reload in game to apply.",
             "local _, ns = ...", "ns.plan = {"]
    lines += [f"    {k} = {_lua_value(v)}," for k, v in plan.items()]
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_plan(install, plan):
    """Write Plan.lua into the installed addon; returns its path."""
    if not install.addon_dir.is_dir():
        raise FileNotFoundError(f"The addon is not installed in {install.addons_dir}; install it first.")
    path = install.plan_file
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(render_plan(plan), encoding="utf-8", newline="\n")
    os.replace(tmp, path)
    return path
