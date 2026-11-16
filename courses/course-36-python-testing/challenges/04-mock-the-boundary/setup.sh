#!/usr/bin/env bash
# Plants the "Mock the Boundary" exercise.
set -euo pipefail

SLUG="04-mock-the-boundary"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

cat > "$WORK/weather.py" << 'PYEOF'
import requests

API = "https://api.example.com/weather"


def get_temp_c(city):
    resp = requests.get(f"{API}/{city}")
    resp.raise_for_status()
    return resp.json()["temp_c"]


def classify(city):
    t = get_temp_c(city)
    if t < 0:
        return "freezing"
    if t < 15:
        return "cold"
    if t < 28:
        return "mild"
    return "hot"


def to_fahrenheit(city):
    return get_temp_c(city) * 9 / 5 + 32
PYEOF

if [ ! -f "$WORK/test_weather.py" ]; then
cat > "$WORK/test_weather.py" << 'PYEOF'
from unittest.mock import patch
import weather


# Example — mock requests where it is USED (weather.requests), then test the
# real parsing logic of get_temp_c.
def test_get_temp_c_parses_field():
    with patch("weather.requests") as mock_requests:
        mock_requests.get.return_value.json.return_value = {"temp_c": 21}
        assert weather.get_temp_c("london") == 21
        mock_requests.get.assert_called_once_with("https://api.example.com/weather/london")


# TODO:
#   - classify across boundaries: -5 -> freezing, 0 -> cold, 14 -> cold,
#     15 -> mild, 27 -> mild, 28 -> hot, 35 -> hot
#     (mock weather.requests to return the temp you want, OR patch
#      weather.get_temp_c directly)
#   - to_fahrenheit: e.g. 0C -> 32.0, 100C -> 212.0, 37C -> 98.6
#
# Remember: the verifier BLOCKS the network. If any test forgets to mock,
# it will fail with a RuntimeError about real network access.
PYEOF
fi

echo
echo "Planted into: $WORK"
echo "  weather.py       — the code under test (read it; do NOT modify it)"
echo "  test_weather.py  — write your tests here (must mock the network)"
echo
echo "One-time setup:  cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest requests"
echo "Iterate:         cd $WORK && .venv/bin/pytest -v"
echo "Verify + flag:   bash courses/course-36-python-testing/challenges/$SLUG/verify.sh"
