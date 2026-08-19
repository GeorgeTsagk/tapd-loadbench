#!/usr/bin/env python3
"""Turn captured pprof profiles into JSON the site can browse.

The browser cannot read pprof protobuf, and shipping a WebAssembly pprof would be
absurd for this, so symbolization happens here at render time and the page gets
plain JSON. Raw profiles stay on disk so `go tool pprof -base` remains available
for anything the page does not show.
"""
import json, os, re, subprocess, sys, pathlib

# The site serves this file out of the repository, so every render commits a
# fresh copy. Keep it small: the tail of a profile is noise anyway.
TOP_N = 45
PROFILES = {"heap": "bytes", "allocs": "bytes", "goroutine": "count"}
ROW = re.compile(r"^\s*(-?[\d.]+)(\w*)\s+([\d.]+)%\s+([\d.]+)%\s+(-?[\d.]+)(\w*)\s+([\d.]+)%\s+(.*)$")
UNITS = {"": 1, "B": 1, "b": 1, "kB": 1000, "KB": 1024, "MB": 1024**2, "GB": 1024**3}


def pprof(args):
    r = subprocess.run(["go", "tool", "pprof"] + args, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def clean(fn):
    """Collapse generic instantiations.

    A generic symbol carries its whole shape inline, and the shape itself contains
    brackets (`[go.shape.[]*pkg.Type]`), so a non-greedy regex stops at the wrong
    one. Match brackets properly instead.
    """
    while (i := fn.find("[go.shape")) != -1:
        depth, j = 0, i
        while j < len(fn):
            if fn[j] == "[":
                depth += 1
            elif fn[j] == "]":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        fn = fn[:i] + "[T]" + fn[j + 1:]
    return fn


def pkg_of(fn):
    """Import path of a symbol, which is how a profile maps onto subsystems.

    tapd sets no pprof labels, so there is no named subsystem dimension; the
    package path is the closest thing and it lines up with the code layout.
    """
    fn = clean(fn).split(" ")[0]
    if "/" in fn:
        head, tail = fn.rsplit("/", 1)
        pkg = head + "/" + tail.split(".")[0]
    else:
        pkg = fn.split(".")[0]
    for prefix, short in (("github.com/lightninglabs/taproot-assets", "tapd"),
                          ("github.com/lightningnetwork/lnd", "lnd"),
                          ("github.com/btcsuite/btcd", "btcd"),
                          ("google.golang.org/grpc", "grpc"),
                          ("github.com/", ""), ("google.golang.org/", ""),
                          ("modernc.org/", "")):
        if pkg.startswith(prefix):
            rest = pkg[len(prefix):].lstrip("/")
            return f"{short}/{rest}" if short and rest else (short or rest or pkg)
    return pkg


def parse_top(text, unit_hint):
    rows = []
    for line in text.splitlines():
        m = ROW.match(line)
        if not m:
            continue
        flat, fu, _, _, cum, cu, cumpct, name = m.groups()
        scale_f = UNITS.get(fu, 1) if unit_hint == "bytes" else 1
        scale_c = UNITS.get(cu, 1) if unit_hint == "bytes" else 1
        rows.append({"fn": clean(name.strip()), "pkg": pkg_of(name.strip()),
                     "flat": int(float(flat) * scale_f),
                     "cum": int(float(cum) * scale_c),
                     "cum_pct": float(cumpct)})
    return rows


def parse_traces(text):
    """Group goroutines by the frame that best identifies them.

    Every parked goroutine sits in runtime.gopark, so the top frame says nothing.
    Walk down for the deepest tapd frame, and fall back to the deepest non-runtime
    frame when none of the stack is ours.
    """
    groups, count, frames = [], None, []

    def flush():
        if count is None or not frames:
            return
        tap = [f for f in frames if "taproot-assets" in f]
        pick = tap[-1] if tap else next(
            (f for f in reversed(frames) if not f.startswith(("runtime.", "internal/"))),
            frames[-1])
        groups.append({"fn": clean(pick), "pkg": pkg_of(pick),
                       "flat": count, "cum": count, "cum_pct": 0.0,
                       "stack": [clean(f) for f in frames[-6:]]})

    for line in text.splitlines():
        if line.startswith("---"):
            flush(); count, frames = None, []
            continue
        m = re.match(r"^\s+(\d+)\s+(\S.*)$", line)
        if m:
            flush(); count, frames = int(m.group(1)), [m.group(2).strip()]
        elif line.strip() and count is not None:
            frames.append(line.strip())
    flush()

    merged = {}
    for g in groups:
        k = g["fn"]
        if k in merged:
            merged[k]["flat"] += g["flat"]; merged[k]["cum"] += g["flat"]
        else:
            merged[k] = g
    out = sorted(merged.values(), key=lambda g: -g["flat"])
    total = sum(g["flat"] for g in out) or 1
    for g in out:
        g["cum_pct"] = round(g["flat"] / total * 100, 2)
    return out


def by_package(rows):
    agg = {}
    for r in rows:
        a = agg.setdefault(r["pkg"], {"pkg": r["pkg"], "flat": 0, "cum": 0, "fns": 0})
        a["flat"] += r["flat"]; a["cum"] = max(a["cum"], r["cum"]); a["fns"] += 1
    out = sorted(agg.values(), key=lambda a: -a["flat"])
    total = sum(a["flat"] for a in out) or 1
    for a in out:
        a["pct"] = round(a["flat"] / total * 100, 2)
    return out


def main():
    root = pathlib.Path(sys.argv[1])
    binary = sys.argv[2]
    out_path = pathlib.Path(sys.argv[3])

    dirs = sorted(d for d in (root / "logs").glob("epoch-*/pprof") if any(d.iterdir()))
    if not dirs:
        print("no profiles captured yet")
        return
    latest, baseline = dirs[-1], dirs[0]
    epoch = int(latest.parent.name.split("-")[1])
    base_epoch = int(baseline.parent.name.split("-")[1])

    result = {"epoch": epoch, "baseline_epoch": base_epoch,
              "profiles_available": len(dirs), "nodes": {}}

    for f in sorted(latest.glob("*.heap.pb.gz")):
        node = f.name.split(".")[0]
        node_out = {}
        for prof, unit in PROFILES.items():
            src = latest / f"{node}.{prof}.pb.gz"
            if not src.exists():
                continue
            if prof == "goroutine":
                rows = parse_traces(pprof(["-traces", binary, str(src)]))
            else:
                rows = parse_top(
                    pprof(["-top", "-unit=b", f"-nodecount={TOP_N}", binary, str(src)]),
                    unit)
            entry = {"unit": unit, "total": sum(r["flat"] for r in rows),
                     "functions": rows[:TOP_N], "packages": by_package(rows)}

            # Growth against the oldest profile on disk: the question a series
            # cannot answer is which call site is responsible.
            old = baseline / f"{node}.{prof}.pb.gz"
            if old.exists() and baseline != latest and prof != "goroutine":
                d = parse_top(pprof(["-top", "-unit=b", f"-nodecount={TOP_N}",
                                     "-base", str(old), binary, str(src)]), unit)
                entry["growth"] = [r for r in d if r["flat"] != 0][:TOP_N]
            node_out[prof] = entry
        result["nodes"][node] = node_out

    # Stacks are only worth carrying for the groups anyone will look at.
    for node in result["nodes"].values():
        g = node.get("goroutine")
        if g:
            for i, row in enumerate(g["functions"]):
                if i >= 20:
                    row.pop("stack", None)

    out_path.write_text(json.dumps(result, separators=(",", ":")))
    tot = sum(len(p.get("functions", [])) for n in result["nodes"].values() for p in n.values())
    print(f"wrote {out_path} (epoch {epoch}, {len(result['nodes'])} nodes, {tot} rows, "
          f"{out_path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
