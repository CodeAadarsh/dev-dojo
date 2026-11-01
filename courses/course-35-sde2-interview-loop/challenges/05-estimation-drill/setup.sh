#!/usr/bin/env bash
# Plants the "Estimation Drill: Metrics Ingestion Pipeline" starter into the
# work directory. Idempotent — safe to re-run; answers.py is not overwritten if
# it already exists (preserves user progress).
set -euo pipefail

SLUG="05-estimation-drill"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── worksheet.md ─────────────────────────────────────────────────────────────
cat > "$WORK/worksheet.md" << 'MDEOF'
# Estimation Worksheet — Metrics Ingestion Pipeline

## Spec

| Parameter                      | Value           |
|--------------------------------|-----------------|
| Monitored hosts                | 5 000           |
| Metrics per host               | 20              |
| Scrape interval                | 10 seconds      |
| Bytes per data point           | 64              |
| Seconds per day                | 86 400          |
| Days per year                  | 365             |
| Load distribution              | uniform (flat)  |

## Your working

<!-- Derive each value step by step. Units matter. -->

### Ingest QPS

data_points_per_scrape  = hosts × metrics_per_host
                        = 5 000 × 20 = ???

ingest_qps              = data_points_per_scrape / scrape_interval_seconds
                        = ??? / 10 = ???

### Storage per year (GiB)

samples_per_day         = ingest_qps × 86 400
                        = ??? × 86 400 = ???

samples_per_year        = samples_per_day × 365
                        = ??? × 365 = ???

bytes_per_year          = samples_per_year × bytes_per_point
                        = ??? × 64 = ???

storage_year_gib        = bytes_per_year / (1 024 × 1 024 × 1 024)
                        = ??? / 1 073 741 824 = ???

### Ingest bandwidth (MiB/s)

bytes_per_second        = ingest_qps × bytes_per_point
                        = ??? × 64 = ???

ingest_bandwidth_mibps  = bytes_per_second / (1 024 × 1 024)
                        = ??? / 1 048 576 = ???

## Notes

- Use GiB (1 GiB = 1024^3 bytes), not GB (10^9).
- Bandwidth is MiB/s (mebibytes), not Mbps (megabits).
- checker.py tolerates ±10%. Sanity-check each figure is plausible before running it.
MDEOF

# ── answers.py — starter; only written if it does not exist ──────────────────
if [ ! -f "$WORK/answers.py" ]; then
cat > "$WORK/answers.py" << 'PYEOF'
# answers.py — fill in your computed values.
# Run:  python3 checker.py
# Then: bash courses/course-35-sde2-interview-loop/challenges/05-estimation-drill/verify.sh

ingest_qps             = 0      # integer — data points arriving per second
storage_year_gib       = 0      # integer — total bytes stored per year, in GiB
ingest_bandwidth_mibps = 0.0    # float   — aggregate ingest throughput in MiB/s
PYEOF
fi

# ── checker.py — always written fresh from setup ──────────────────────────────
cat > "$WORK/checker.py" << 'PYEOF'
#!/usr/bin/env python3
"""checker.py — validates capacity estimates for the metrics ingestion pipeline.

Reference derivation:
  hosts                 = 5_000
  metrics_per_host      = 20
  scrape_interval_s     = 10
  bytes_per_point       = 64
  seconds_per_day       = 86_400
  days_per_year         = 365

  ingest_qps            = 5_000 * 20 / 10                = 10_000 qps
  samples_per_year      = 10_000 * 86_400 * 365          = 315_360_000_000
  bytes_per_year        = 315_360_000_000 * 64           = 20_183_040_000_000
  storage_year_gib      = 20_183_040_000_000 / 1024**3  ≈ 18_796 GiB
  ingest_bandwidth_mibps= 10_000 * 64 / 1024**2         ≈ 0.610 MiB/s
"""
import sys

CORRECT = {
    "ingest_qps":             10_000,
    "storage_year_gib":       18_796,
    "ingest_bandwidth_mibps": 0.610,
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
        print(f"  ok {label}: {got}{unit}  (expected ~{expected}{unit}, ±{int(tol*100)}%)")
        return True
    print(f"  x  {label}: {got}{unit}  (expected {lo:.2f}–{hi:.2f}{unit})")
    return False


results = [
    check("ingest_qps",
          getattr(answers, "ingest_qps",             MISSING), CORRECT["ingest_qps"],             TOLERANCE),
    check("storage_year_gib",
          getattr(answers, "storage_year_gib",        MISSING), CORRECT["storage_year_gib"],        TOLERANCE, " GiB"),
    check("ingest_bandwidth_mibps",
          getattr(answers, "ingest_bandwidth_mibps",  MISSING), CORRECT["ingest_bandwidth_mibps"],  TOLERANCE, " MiB/s"),
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
echo "Task           : compute ingest QPS, storage/year (GiB), and ingest bandwidth"
echo "                 (MiB/s) for the metrics pipeline spec. Edit answers.py."
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
echo "Verify + flag  : bash courses/course-35-sde2-interview-loop/challenges/$SLUG/verify.sh"
