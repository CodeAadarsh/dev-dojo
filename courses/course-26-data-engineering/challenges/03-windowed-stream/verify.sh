#!/usr/bin/env bash
# Verifier for "Windowed Stream: Tumbling Windows with Late Events".
# The event stream is embedded here (fixed, deterministic). Runs hidden pytest.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-windowed-stream"
FLAG='KUBE{tumbling_window_late_events}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/windowed.py" ] || fail "windowed.py not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMPDIR_HIDDEN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_HIDDEN"' EXIT

cat > "$TMPDIR_HIDDEN/test_windowed_hidden.py" << PYEOF
import sys, os
sys.path.insert(0, "$WORK")

from windowed import compute_windows

# Fixed deterministic stream — same in setup.sh visible test and here
EVENTS = [
    ("sensor-A", 10,  5),
    ("sensor-B", 15,  3),
    ("sensor-A", 25,  8),
    ("sensor-B", 70,  4),
    ("sensor-A", 75,  2),
    ("sensor-B", 80,  6),
    ("sensor-A", 130, 9),
    ("sensor-B", 129, 7),   # out-of-order late event
    ("sensor-A", 195, 1),
    ("sensor-B", 200, 2),
]


def result():
    return compute_windows(EVENTS, window_size_s=60, max_lateness_s=10)


def test_returns_dict():
    assert isinstance(result(), dict)


def test_window_count():
    r = result()
    assert len(r) == 8, f"expected 8 windows, got {len(r)}: {sorted(r.keys())}"


def test_sensor_a_window_0():
    r = result()
    assert r[("sensor-A", 0)] == 13, \
        f"sensor-A [0,60): expected 13 (ts=10->5, ts=25->8), got {r.get(('sensor-A',0))}"


def test_sensor_b_window_0():
    r = result()
    assert r[("sensor-B", 0)] == 3, \
        f"sensor-B [0,60): expected 3 (ts=15->3), got {r.get(('sensor-B',0))}"


def test_sensor_a_window_60():
    r = result()
    assert r[("sensor-A", 60)] == 2, \
        f"sensor-A [60,120): expected 2 (ts=75->2), got {r.get(('sensor-A',60))}"


def test_sensor_b_window_60():
    r = result()
    assert r[("sensor-B", 60)] == 10, \
        f"sensor-B [60,120): expected 10 (ts=70->4, ts=80->6), got {r.get(('sensor-B',60))}"


def test_sensor_a_window_120():
    r = result()
    assert r[("sensor-A", 120)] == 9, \
        f"sensor-A [120,180): expected 9 (ts=130->9), got {r.get(('sensor-A',120))}"


def test_sensor_b_window_120_late_event():
    """The critical test: ts=129 arrives after ts=130, but watermark is 120, so it is accepted."""
    r = result()
    wm_when_129_arrives = 130 - 10  # = 120; 129 >= 120 -> must be accepted
    assert r.get(("sensor-B", 120)) == 7, (
        f"sensor-B [120,180): expected 7 (late event ts=129 within lateness budget), "
        f"got {r.get(('sensor-B',120))}. "
        f"Watermark when ts=129 arrives = {wm_when_129_arrives}; event ts=129 >= {wm_when_129_arrives} -> accept."
    )


def test_sensor_a_window_180():
    r = result()
    assert r[("sensor-A", 180)] == 1, \
        f"sensor-A [180,240): expected 1 (ts=195->1), got {r.get(('sensor-A',180))}"


def test_sensor_b_window_180():
    r = result()
    assert r[("sensor-B", 180)] == 2, \
        f"sensor-B [180,240): expected 2 (ts=200->2), got {r.get(('sensor-B',180))}"


def test_no_extra_windows():
    r = result()
    expected_keys = {
        ("sensor-A", 0), ("sensor-B", 0),
        ("sensor-A", 60), ("sensor-B", 60),
        ("sensor-A", 120), ("sensor-B", 120),
        ("sensor-A", 180), ("sensor-B", 180),
    }
    extra = set(r.keys()) - expected_keys
    assert not extra, f"unexpected window keys: {extra}"


def test_window_start_multiples():
    """All window_start values must be multiples of window_size_s=60."""
    r = result()
    for (key, ws) in r.keys():
        assert ws % 60 == 0, f"window_start {ws} for key {key} is not a multiple of 60"


def test_values_are_ints():
    r = result()
    for k, v in r.items():
        assert isinstance(v, int), f"window {k} sum must be int, got {type(v)}: {v}"
PYEOF

if $PYTEST "$TMPDIR_HIDDEN/test_windowed_hidden.py" -q 2>&1; then
    echo
    echo "All hidden assertions passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "hidden test suite has failures — review brief.md and retry"
fi
