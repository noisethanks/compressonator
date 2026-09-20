#!/usr/bin/env python3
# Q=0.25/0.45/0.65/0.85 centibucket boundary sweep.
# Portable version — no /tmp hardcoding, no fixed abs paths.
#
# Reference MD5s: NOTES.md Phase 3 part 4c (post-centibucket-fix table).
#   veryfast  Q=0.05  md5=5fae5456ae19
#   fast      Q=0.30  md5=cff9a2cf1964
#   basic     Q=0.50  md5=10cda379ba6f
#   slow      Q=0.70  md5=16c8a5170408
#   slowest   Q=0.95  md5=7f115eab183c
# Boundaries expected:
#   Q=0.25 → fast     (cff9a2cf1964)
#   Q=0.45 → basic    (10cda379ba6f)
#   Q=0.65 → slow     (16c8a5170408)
#   Q=0.85 → slowest  (7f115eab183c)
#
# Cross-platform gotchas (Linux run recorded in NOTES.md; Windows may
# differ if the compiler produces different rounding in bc7e.ispc's
# scalar helpers — investigate any mismatch before flagging it a bug):
# a same-tree same-CLI-args mismatch versus these reference MD5s can
# mean either a real regression or a legitimate cross-compiler FP diff.

import os, subprocess, hashlib, argparse, sys, tempfile
from pathlib import Path

REF = {
    "veryfast": ("0.05", "5fae5456ae19"),
    "fast":     ("0.30", "cff9a2cf1964"),
    "basic":    ("0.50", "10cda379ba6f"),
    "slow":     ("0.70", "16c8a5170408"),
    "slowest":  ("0.95", "7f115eab183c"),
}
BOUNDARIES = [("0.25","fast"), ("0.45","basic"), ("0.65","slow"), ("0.85","slowest")]

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--cli", required=True,
                   help="path to compressonatorcli-bin (or .exe)")
    p.add_argument("--src", required=True,
                   help="path to reference PNG (compressonator/runtime/images/ruby.png)")
    p.add_argument("--tmp", default=None,
                   help="scratch dir (default: system temp)")
    p.add_argument("--threads", type=int, default=8)
    return p.parse_args()

def enc(cli, src, q, out, nt):
    subprocess.run([cli, "-fd", "BC7", "-EncodeWith", "CPU",
                    "-Quality", str(q), "-NumThreads", str(nt),
                    str(src), str(out)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def md5(p):
    return hashlib.md5(Path(p).read_bytes()).hexdigest()[:12]

def mode_hist(dds):
    d = Path(dds).read_bytes()
    hdr = 148 if d[84:88] == b"DX10" else 128
    p = d[hdr:]
    h = [0]*8; inv = 0
    for i in range(0, len(p), 16):
        b0 = p[i]
        if b0 == 0: inv += 1; continue
        m = 0
        while m < 8 and not (b0 & (1<<m)): m += 1
        if m < 8: h[m] += 1
        else: inv += 1
    return h, inv

def main():
    a = parse_args()
    cli = Path(a.cli).resolve()
    src = Path(a.src).resolve()
    if not cli.exists(): sys.exit(f"cli not found: {cli}")
    if not src.exists(): sys.exit(f"src not found: {src}")
    tmp = Path(a.tmp) if a.tmp else Path(tempfile.gettempdir()) / "cmp_verify"
    tmp.mkdir(parents=True, exist_ok=True)
    os.environ["OMP_NUM_THREADS"] = str(a.threads)

    print("Reference (interior) values:")
    ref_ok = True
    for name, (q, expected) in REF.items():
        out = tmp / f"vb_ref_{name}.dds"
        enc(cli, src, q, out, a.threads)
        got = md5(out)
        ok = "OK" if got == expected else f"MISMATCH (expected {expected})"
        print(f"  {name:<9} Q={q}  md5={got}  {ok}")
        if got != expected: ref_ok = False

    print()
    print("Boundary values:")
    boundary_ok = True
    for q, expected_bucket in BOUNDARIES:
        out = tmp / f"vb_b_{q.replace('.','')}.dds"
        enc(cli, src, q, out, a.threads)
        got = md5(out)
        h, _ = mode_hist(out)
        match = None
        for name, (_, ref_md5) in REF.items():
            if got == ref_md5:
                match = name; break
        row = " ".join(f"m{i}:{h[i]}" for i in range(8))
        verdict = "OK" if match == expected_bucket else f"WRONG (expected {expected_bucket}, got {match})"
        print(f"  Q={q}  md5={got}  bucket={match}  {verdict}")
        print(f"        hist: {row}")
        if match != expected_bucket: boundary_ok = False

    if not ref_ok or not boundary_ok:
        sys.exit(1)

if __name__ == "__main__":
    main()
