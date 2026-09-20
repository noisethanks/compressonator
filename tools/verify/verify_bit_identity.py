#!/usr/bin/env python3
# Block-by-block bit-identity between the per-block (build_cli) and
# batched (build_cli_batch) bc7e paths. Portable version.
#
# Coverage (Step 2/2b — see NOTES.md Phase 3 part 5):
#   1. ruby.png Q=0.50           (interior)
#   2. ruby.png Q=0.45           (boundary — was misresolved pre-fix)
#   3. ruby.png Q=0.65           (boundary — was misresolved pre-fix)
#   4. ruby.png Q=0.50 -ColourRestrict 1 -ModeMask 255
#   5. ruby_alpha.tga Q=0.50 -AlphaRestrict 1 -ModeMask 255
#   6. ruby_alpha.tga Q=0.50 -ColourRestrict 1 -AlphaRestrict 1 -ModeMask 255
#
# Note: -ModeMask 255 is required on any test using -ColourRestrict/
# -AlphaRestrict. The default ModeMask=0xCF combined with alphaRestrict
# leaves zero valid alpha modes and hits the Step 2b defensive guard
# (see NOTES.md Phase 3 part 5 Step 2b). The guard prevents a crash
# but is not a bit-identity contract on that specific input.

import os, subprocess, hashlib, sys, argparse, tempfile
from pathlib import Path

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--unbatch", required=True, help="path to build_cli compressonatorcli")
    p.add_argument("--batch",   required=True, help="path to build_cli_batch compressonatorcli")
    p.add_argument("--ruby",       required=True, help="path to ruby.png")
    p.add_argument("--ruby-alpha", required=True, help="path to ruby_alpha.tga")
    p.add_argument("--tmp", default=None)
    p.add_argument("--threads", type=int, default=8)
    return p.parse_args()

def enc(bin_path, src, q, out, nt, extra=None):
    cmd = [str(bin_path), "-fd", "BC7", "-EncodeWith", "CPU",
           "-Quality", str(q), "-NumThreads", str(nt)]
    if extra: cmd += extra
    cmd += [str(src), str(out)]
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        print(f"  FAIL: exit={r.returncode} stderr={r.stderr.decode(errors='ignore')[:200]}")
        sys.exit(1)

def payload(dds):
    d = Path(dds).read_bytes()
    hdr = 148 if d[84:88] == b"DX10" else 128
    return d[hdr:], d[:hdr]

def compare(a_path, b_path, label):
    pa, ha = payload(a_path)
    pb, hb = payload(b_path)
    if len(pa) != len(pb):
        print(f"  [{label}] LENGTH MISMATCH: unbatch={len(pa)}  batch={len(pb)}")
        return False
    n = len(pa) // 16
    mm = sum(1 for i in range(n) if pa[i*16:(i+1)*16] != pb[i*16:(i+1)*16])
    rate = 100.0 * (n - mm) / n if n else 0
    am = hashlib.md5(pa).hexdigest()[:12]
    bm = hashlib.md5(pb).hexdigest()[:12]
    verdict = "OK" if mm == 0 else f"MISMATCH ({mm}/{n} blocks differ)"
    print(f"  [{label}] blocks={n} match={n-mm}/{n} ({rate:.4f}%)  "
          f"unbatch={am} batch={bm}  {verdict}")
    return mm == 0

def main():
    a = parse_args()
    UB = Path(a.unbatch).resolve()
    BA = Path(a.batch).resolve()
    RUBY = Path(a.ruby).resolve()
    RUBY_A = Path(getattr(a, 'ruby_alpha')).resolve()
    tmp = Path(a.tmp) if a.tmp else Path(tempfile.gettempdir()) / "cmp_bit_identity"
    tmp.mkdir(parents=True, exist_ok=True)
    for p in [UB, BA, RUBY, RUBY_A]:
        if not p.exists(): sys.exit(f"missing: {p}")
    os.environ["OMP_NUM_THREADS"] = str(a.threads)

    TESTS = [
        ("ruby.png Q=0.50",                                       RUBY,   "0.50", None),
        ("ruby.png Q=0.45 (boundary)",                            RUBY,   "0.45", None),
        ("ruby.png Q=0.65 (boundary)",                            RUBY,   "0.65", None),
        ("ruby.png Q=0.50 -ColourRestrict 1 -ModeMask 255",       RUBY,   "0.50",
            ["-ColourRestrict", "1", "-ModeMask", "255"]),
        ("ruby_alpha.tga Q=0.50 -AlphaRestrict 1 -ModeMask 255",  RUBY_A, "0.50",
            ["-AlphaRestrict", "1", "-ModeMask", "255"]),
        ("ruby_alpha.tga Q=0.50 -Colour 1 -Alpha 1 -ModeMask 255", RUBY_A, "0.50",
            ["-ColourRestrict", "1", "-AlphaRestrict", "1", "-ModeMask", "255"]),
    ]
    all_ok = True
    for i, (label, src, q, extra) in enumerate(TESTS):
        up = tmp / f"bd_unbatch_{i}.dds"
        bp = tmp / f"bd_batch_{i}.dds"
        enc(UB, src, q, up, a.threads, extra)
        enc(BA, src, q, bp, a.threads, extra)
        if not compare(up, bp, label): all_ok = False

    print()
    print("ALL BIT-IDENTICAL" if all_ok else "AT LEAST ONE TEST HAS MISMATCHES — INVESTIGATE")
    if not all_ok: sys.exit(1)

if __name__ == "__main__":
    main()
