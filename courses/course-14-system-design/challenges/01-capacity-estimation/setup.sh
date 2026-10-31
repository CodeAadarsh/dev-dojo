#!/usr/bin/env bash
# Plants the "Capacity Estimation" starter into the work directory.
# Idempotent — safe to re-run; existing answers.py is not overwritten.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-capacity-estimation"
mkdir -p "$WORK"

# ── worksheet.md — spec + scratch pad ───────────────────────────────────────
cat > "$WORK/worksheet.md" << 'MDEOF'
# Capacity Estimation Worksheet — 100M-DAU Social Feed

## Spec

| Parameter                  | Value           |
|----------------------------|-----------------|
| Daily Active Users (DAU)   | 100 000 000     |
| Posts per user per day     | 10              |
| Average post size          | 1 KB (1 024 B)  |
| Seconds per day            | 86 400          |
| Write traffic distribution | uniform (flat)  |

## Your working

<!-- Derive each value step-by-step. Units matter. -->

### Writes per second

write_volume_per_day = DAU × posts_per_user_per_day
                     = ??? × ??? = ???

writes_per_sec = write_volume_per_day / seconds_per_day
              = ??? / 86 400 = ???

### Storage per year (GiB)

bytes_per_day  = write_volume_per_day × post_size_bytes
              = ??? × 1 024 = ???

bytes_per_year = bytes_per_day × 365 = ???

storage_year_gib = bytes_per_year / (1 024 × 1 024 × 1 024) = ???

### Write bandwidth (MiB/s)

write_bandwidth_bytes_per_sec = writes_per_sec × post_size_bytes
                              = ??? × 1 024 = ???

write_bandwidth_mibps = write_bandwidth_bytes_per_sec / (1 024 × 1 024) = ???

## Notes

- Round to 4 significant figures. checker.py tolerates ±10%.
- For storage, use binary GiB (1 GiB = 1024^3 bytes), not decimal GB.
- Bandwidth: MiB/s = mebibytes per second (binary), not Mbps (bits).
MDEOF

# ── answers.py — starter; only written if it does not exist yet ─────────────
if [ ! -f "$WORK/answers.py" ]; then
cat > "$WORK/answers.py" << 'PYEOF'
# answers.py — fill in your computed values.
# Run:  python3 checker.py
# Then: bash courses/course-14-system-design/challenges/01-capacity-estimation/verify.sh

writes_per_sec       = 0     # integer  — posts written per second at uniform load
storage_year_gb      = 0     # integer  — total storage added per year, in GiB
write_bandwidth_mbps = 0.0   # float    — aggregate write throughput in MiB/s
PYEOF
fi

# ── checker.py — validator; always written fresh from setup ─────────────────
cat > "$WORK/checker.py" << 'PYEOF'
#!/usr/bin/env python3
"""checker.py — validates capacity estimates for the 100M-DAU social feed.

Correct reference figures:
  DAU                  = 100_000_000
  posts/user/day       = 10
  post_size_bytes      = 1_024
  seconds_per_day      = 86_400

  writes_per_sec       = 100_000_000 * 10 / 86_400       = 11_574.07...  (floor: 11_574)
  storage_year_gib     = 100_000_000 * 10 * 1_024 * 365
                         / (1_024**3)                     = 339_813....   GiB
  write_bandwidth_mibps= 11_574.07 * 1_024 / (1_024**2)  = 11.303...     MiB/s
"""
import sys

CORRECT = {
    "writes_per_sec":       11574,
    "storage_year_gb":      348091,
    "write_bandwidth_mbps": 11.3,
}
TOLERANCE = 0.10

try:
    import answers
except ImportError:
    print("answers.py not found in the current directory.")
    sys.exit(1)

MISSING = object()

def check(label, got, expected, tol, unit=""):
    if got is MISSING or got is None:
        print(f"  x  {label}: not set")
        return False
    lo, hi = expected * (1 - tol), expected * (1 + tol)
    if lo <= got <= hi:
        print(f"  ok {label}: {got}{unit}  (expected ~{expected}{unit}, +-{int(tol*100)}%)")
        return True
    print(f"  x  {label}: {got}{unit}  (expected {lo:.1f}-{hi:.1f}{unit})")
    return False

results = [
    check("writes_per_sec",       getattr(answers, "writes_per_sec",       MISSING), CORRECT["writes_per_sec"],       TOLERANCE),
    check("storage_year_gb (GiB)",getattr(answers, "storage_year_gb",      MISSING), CORRECT["storage_year_gb"],      TOLERANCE, " GiB"),
    check("write_bandwidth_mbps", getattr(answers, "write_bandwidth_mbps", MISSING), CORRECT["write_bandwidth_mbps"], TOLERANCE, " MiB/s"),
]

if all(results):
    print("\nAll estimates within tolerance.")
    sys.exit(0)
else:
    print("\nOne or more estimates are off. Re-read worksheet.md and recheck your arithmetic.")
    sys.exit(1)
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : compute writes/sec, storage/year (GiB), and write bandwidth"
echo "                 (MiB/s) for the given spec. Edit answers.py with your values."
echo
echo "Files:"
echo "  worksheet.md  — spec + formula guide (your scratch pad)"
echo "  answers.py    — set the three variables here"
echo "  checker.py    — run to see which values pass"
echo
echo "Quick start:"
echo "  cd $WORK"
echo "  python3 checker.py"
echo
echo "Verify + flag  : bash courses/course-14-system-design/challenges/01-capacity-estimation/verify.sh"
