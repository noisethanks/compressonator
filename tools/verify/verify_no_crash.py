#!/usr/bin/env python3
# Confirms the zero-valid-modes crash config (documented in NOTES.md
# Phase 3 part 5 Step 2b) doesn't crash on either binary. Portable.
#
# The crashing config was: `-AlphaRestrict 1` on an image with hard
# alpha, with the default -ModeMask (0xCF). Default ModeMask disables
# modes 4/5 (alpha modes); alphaRestrict disables modes 6/7 as well;
# result = zero valid alpha modes for any alpha-bearing block. Batched
# bc7e's SIMD path OOB-writes on uninitialized opt_results; per-block
# path masks it because ISPC lane count is 1; stock silently produces
# garbage. The Step 2b guard routes such blocks to the unrestricted
# default params rather than the empty set.
#
# Success = both binaries exit 0. No bit-identity check here — this
# is purely a "does not crash" gate.
import subprocess, sys, argparse, tempfile
from pathlib import Path

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--unbatch", required=True)
    p.add_argument("--batch",   required=True)
    p.add_argument("--ruby-alpha", required=True)
    p.add_argument("--tmp", default=None)
    p.add_argument("--threads", type=int, default=8)
    a = p.parse_args()
    tmp = Path(a.tmp) if a.tmp else Path(tempfile.gettempdir()) / "cmp_zvm"
    tmp.mkdir(parents=True, exist_ok=True)
    src = Path(getattr(a, 'ruby_alpha')).resolve()
    if not src.exists(): sys.exit(f"missing: {src}")

    ok = True
    for label, binp in [("build_cli (per-block)", a.unbatch),
                        ("build_cli_batch (batched)", a.batch)]:
        out = tmp / f"zvm_{label.split()[0]}.dds"
        cmd = [str(binp), "-fd", "BC7", "-EncodeWith", "CPU",
               "-Quality", "0.5", "-NumThreads", str(a.threads),
               "-AlphaRestrict", "1", str(src), str(out)]
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        status = "no crash" if r.returncode == 0 else f"CRASHED (exit={r.returncode})"
        print(f"  {label:32s}  {status}")
        if r.returncode != 0:
            print(f"    stderr: {r.stderr.decode(errors='ignore')[:200]}")
            ok = False
    if not ok: sys.exit(1)

if __name__ == "__main__":
    main()
