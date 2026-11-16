#!/usr/bin/env bash
# Verifier for "Mock the Boundary".
# A conftest blocks all real sockets, so un-mocked network calls fail loudly.
# Your suite must pass on correct weather.py and fail on every mutant.
set -uo pipefail

SLUG="04-mock-the-boundary"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{mock_the_boundary_not_the_logic}'

fail() { echo "✗ $1"; exit 1; }

[ -f "$WORK/test_weather.py" ] || fail "test_weather.py not found — run setup.sh and write your tests first"

grep -Eq "patch|Mock|monkeypatch|mocker|responses|requests_mock" "$WORK/test_weather.py" || \
    fail "no mocking found in your tests — this challenge requires mocking the network (unittest.mock patch/Mock or monkeypatch)"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
    PYBIN="$WORK/.venv/bin/python"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
    PYBIN="python3"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest requests"
fi

"$PYBIN" -c "import requests" 2>/dev/null || \
    fail "the 'requests' package is not installed — cd $WORK && . .venv/bin/activate && pip install requests"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$WORK/test_weather.py" "$TMP/test_weather.py"

# Block all real network access during the test run.
cat > "$TMP/conftest.py" << 'PYEOF'
import socket
import pytest


@pytest.fixture(autouse=True)
def _no_real_network(monkeypatch):
    def _guard(*args, **kwargs):
        raise RuntimeError("real network access in a test — mock the boundary!")
    monkeypatch.setattr(socket, "socket", _guard)
    monkeypatch.setattr(socket, "create_connection", _guard)
PYEOF

emit() {
    case "$1" in
    correct)
cat > "$TMP/weather.py" << 'PYEOF'
import requests
API = "https://api.example.com/weather"
def get_temp_c(city):
    resp = requests.get(f"{API}/{city}")
    resp.raise_for_status()
    return resp.json()["temp_c"]
def classify(city):
    t = get_temp_c(city)
    if t < 0: return "freezing"
    if t < 15: return "cold"
    if t < 28: return "mild"
    return "hot"
def to_fahrenheit(city):
    return get_temp_c(city) * 9 / 5 + 32
PYEOF
        ;;
    freezing_boundary)   # 0 becomes freezing
cat > "$TMP/weather.py" << 'PYEOF'
import requests
API = "https://api.example.com/weather"
def get_temp_c(city):
    resp = requests.get(f"{API}/{city}")
    resp.raise_for_status()
    return resp.json()["temp_c"]
def classify(city):
    t = get_temp_c(city)
    if t <= 0: return "freezing"
    if t < 15: return "cold"
    if t < 28: return "mild"
    return "hot"
def to_fahrenheit(city):
    return get_temp_c(city) * 9 / 5 + 32
PYEOF
        ;;
    cold_boundary)   # 15 becomes cold instead of mild
cat > "$TMP/weather.py" << 'PYEOF'
import requests
API = "https://api.example.com/weather"
def get_temp_c(city):
    resp = requests.get(f"{API}/{city}")
    resp.raise_for_status()
    return resp.json()["temp_c"]
def classify(city):
    t = get_temp_c(city)
    if t < 0: return "freezing"
    if t < 16: return "cold"
    if t < 28: return "mild"
    return "hot"
def to_fahrenheit(city):
    return get_temp_c(city) * 9 / 5 + 32
PYEOF
        ;;
    hot_boundary)   # 28 becomes mild instead of hot
cat > "$TMP/weather.py" << 'PYEOF'
import requests
API = "https://api.example.com/weather"
def get_temp_c(city):
    resp = requests.get(f"{API}/{city}")
    resp.raise_for_status()
    return resp.json()["temp_c"]
def classify(city):
    t = get_temp_c(city)
    if t < 0: return "freezing"
    if t < 15: return "cold"
    if t <= 28: return "mild"
    return "hot"
def to_fahrenheit(city):
    return get_temp_c(city) * 9 / 5 + 32
PYEOF
        ;;
    fahrenheit_formula)   # forgot the +32
cat > "$TMP/weather.py" << 'PYEOF'
import requests
API = "https://api.example.com/weather"
def get_temp_c(city):
    resp = requests.get(f"{API}/{city}")
    resp.raise_for_status()
    return resp.json()["temp_c"]
def classify(city):
    t = get_temp_c(city)
    if t < 0: return "freezing"
    if t < 15: return "cold"
    if t < 28: return "mild"
    return "hot"
def to_fahrenheit(city):
    return get_temp_c(city) * 9 / 5
PYEOF
        ;;
    wrong_field)   # reads the wrong JSON key
cat > "$TMP/weather.py" << 'PYEOF'
import requests
API = "https://api.example.com/weather"
def get_temp_c(city):
    resp = requests.get(f"{API}/{city}")
    resp.raise_for_status()
    return resp.json()["temp"]
def classify(city):
    t = get_temp_c(city)
    if t < 0: return "freezing"
    if t < 15: return "cold"
    if t < 28: return "mild"
    return "hot"
def to_fahrenheit(city):
    return get_temp_c(city) * 9 / 5 + 32
PYEOF
        ;;
    esac
}

run() {
    rm -rf "$TMP/__pycache__"
    ( cd "$TMP" && PYTHONDONTWRITEBYTECODE=1 "$PYTEST" -q -p no:cacheprovider test_weather.py >"$TMP/_out.txt" 2>&1 )
    return $?
}

emit correct
if ! run; then
    echo "✗ Your tests FAIL against the correct weather.py (with the network blocked)."
    echo "  If you see 'real network access in a test', you forgot to mock somewhere."
    echo "─────────────────────────────────────────────"
    sed -n '1,45p' "$TMP/_out.txt"
    exit 1
fi

MUTANTS="freezing_boundary:0°C classified as 'freezing' instead of 'cold'
cold_boundary:15°C classified as 'cold' instead of 'mild'
hot_boundary:28°C classified as 'mild' instead of 'hot'
fahrenheit_formula:to_fahrenheit missing the +32 offset
wrong_field:get_temp_c reading the wrong JSON field (not 'temp_c')"

survived=0
while IFS=: read -r name desc; do
    [ -z "$name" ] && continue
    emit "$name"
    if run; then
        echo "✗ Your suite still PASSES with this bug: $desc"
        survived=1
    fi
done <<< "$MUTANTS"

[ "$survived" -eq 0 ] || fail "some logic bugs slipped through — cover the boundaries and the parsed field, then retry"

echo
echo "All checks passed — network mocked, every logic bug caught. Submit this flag:"
echo
echo "    $FLAG"
