#!/usr/bin/env bash
# Plants the Windowed Stream starter into the work directory.
# Idempotent — re-running regenerates tests but preserves windowed.py if it exists.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-windowed-stream"
mkdir -p "$WORK/tests"

# ── windowed.py stub (only write if not present) ─────────────────────────────
if [ ! -f "$WORK/windowed.py" ]; then
cat > "$WORK/windowed.py" << 'PYEOF'
# windowed.py
# Implement compute_windows() as described in brief.md.
# No external dependencies required — pure Python.


def compute_windows(events, window_size_s=60, max_lateness_s=10):
    """
    Compute tumbling-window sums per key.

    Parameters
    ----------
    events       : list of (key: str, ts: int, value: int)
                   Delivered in processing order (may be out of event-time order).
    window_size_s: int  — window width in seconds (default 60)
    max_lateness_s: int — lateness budget; watermark = max_seen_ts - max_lateness_s

    Returns
    -------
    dict  keyed by (key, window_start: int)  ->  sum of values (int)

    Lateness rule:
        watermark starts at -infinity (accept everything until first event).
        After processing each event, watermark = max(all_seen_ts) - max_lateness_s.
        An event is accepted if its ts >= current watermark at processing time.
        Late events (ts < watermark) are silently dropped.
    """
    # TODO: implement
    raise NotImplementedError("implement compute_windows()")
PYEOF
fi

# ── visible test harness ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_windowed_visible.py" << 'PYEOF'
"""Visible sanity tests — pass these before running the verifier."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from windowed import compute_windows

# Shared stream (same as the verifier uses)
EVENTS = [
    ("sensor-A", 10,  5),
    ("sensor-B", 15,  3),
    ("sensor-A", 25,  8),
    ("sensor-B", 70,  4),
    ("sensor-A", 75,  2),
    ("sensor-B", 80,  6),
    ("sensor-A", 130, 9),
    ("sensor-B", 129, 7),   # out-of-order: arrives after ts=130
    ("sensor-A", 195, 1),
    ("sensor-B", 200, 2),
]


def test_returns_dict():
    result = compute_windows(EVENTS)
    assert isinstance(result, dict), "compute_windows must return a dict"


def test_sensor_a_window0():
    result = compute_windows(EVENTS)
    assert result.get(("sensor-A", 0)) == 13, \
        f"sensor-A window [0,60) expected sum=13, got {result.get(('sensor-A',0))}"


def test_sensor_b_window60():
    result = compute_windows(EVENTS)
    assert result.get(("sensor-B", 60)) == 10, \
        f"sensor-B window [60,120) expected sum=10, got {result.get(('sensor-B',60))}"


def test_late_event_accepted():
    result = compute_windows(EVENTS)
    # ts=129 is out-of-order but within 10s lateness of watermark=120
    assert result.get(("sensor-B", 120)) == 7, \
        f"sensor-B window [120,180) expected sum=7 (late event), got {result.get(('sensor-B',120))}"


def test_window_count():
    result = compute_windows(EVENTS)
    assert len(result) == 8, \
        f"expected 8 windows, got {len(result)}: {list(result.keys())}"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement compute_windows() in windowed.py."
echo "                 The event stream, lateness rule, and expected output"
echo "                 are described in brief.md."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run visible tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag     : bash courses/course-26-data-engineering/challenges/03-windowed-stream/verify.sh"
