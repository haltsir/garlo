#!/usr/bin/env python3
"""Anonymise a recorded fixture in place so it can be published.

Every file path becomes a neutral placeholder under its volume root
(the rules only need the volume and the size), process names outside a
small allowlist become app-N, bundle identifiers are dropped for those,
and the recording note is replaced. Placeholders are deterministic per
run, so one file keeps one name across frames and the layouts map.

    python3 Tools/scrub-fixture.py Tests/GarloCoreTests/Fixtures/<name>.json
"""
import json, os, sys

KEEP_NAMES = {"Torrent", "cp", "yes", "bash", "sleep", "Finder", "garlo", "Garlo", "kernel_task"}
KEEP_BUNDLES = {"com.example.torrent", "com.strahil.garlo", "com.apple.finder"}
ROOTS = ["/System/Volumes/Data", "/Volumes/"]
# The machine's own names (volumes, drive models, the torrent client) become
# generic ones in every string of the file. The table lives outside the
# repository so the real names never ship: Tools/scrub-renames.json
# (gitignored), {"renames": [[old, new], ...], "keep": [process names]}.
RENAMES = []
LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scrub-renames.json")
if os.path.exists(LOCAL):
    with open(LOCAL) as fh:
        local = json.load(fh)
    RENAMES = [tuple(pair) for pair in local.get("renames", [])]
    KEEP_NAMES |= set(local.get("keep", []))
    KEEP_BUNDLES |= set(local.get("keepBundles", []))

def rename(value):
    if isinstance(value, str):
        for old, new in RENAMES:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [rename(v) for v in value]
    if isinstance(value, dict):
        return {k: rename(v) for k, v in value.items()}
    return value

paths, names = {}, {}

def scrub_path(p):
    if p in paths:
        return paths[p]
    root = "/Users/user"
    for r in ROOTS:
        if p.startswith(r):
            if r == "/Volumes/":
                parts = p.split("/")
                root = "/".join(parts[:3])  # /Volumes/<name>
            else:
                root = "/Users/user"
            break
    ext = os.path.splitext(p)[1] if len(os.path.splitext(p)[1]) <= 6 else ""
    paths[p] = f"{root}/file-{len(paths) + 1}{ext}"
    return paths[p]

def scrub_name(n):
    if n in KEEP_NAMES:
        return n
    if n not in names:
        names[n] = f"app-{len(names) + 1}"
    return names[n]

def scrub_process(proc):
    proc["name"] = scrub_name(proc["name"])
    if proc.get("bundleID") not in KEEP_BUNDLES:
        proc.pop("bundleID", None)
    return proc

def scrub(rec):
    rec["note"] = "recorded on a real machine, paths and process names anonymised by Tools/scrub-fixture.py"
    for frame in rec["frames"]:
        frame["processes"] = [scrub_process(p) for p in frame.get("processes", [])]
        # Swift encodes [Int32: [OpenFile]] as a flat [key, value, key, value] array
        open_files = frame.get("openFiles") or []
        groups = open_files.values() if isinstance(open_files, dict) else open_files[1::2]
        for files in groups:
            for f in files:
                f["path"] = scrub_path(f["path"])
        for p in frame.get("processNet") or []:
            p["name"] = scrub_name(p["name"])
    layouts = rec.get("layouts") or {}
    rec["layouts"] = {scrub_path(k): (dict(v, path=scrub_path(v["path"])) if isinstance(v, dict) else v) for k, v in layouts.items()}
    return rec

for arg in sys.argv[1:]:
    with open(arg) as fh:
        rec = json.load(fh)
    rec = rename(scrub(rec))
    with open(arg, "w") as fh:
        json.dump(rec, fh, sort_keys=True, separators=(",", ":"))
    print(f"{arg}: {len(paths)} paths, {len(names)} process names anonymised")
