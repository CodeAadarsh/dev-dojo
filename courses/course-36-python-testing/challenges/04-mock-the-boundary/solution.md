# Solution — Mock the Boundary

Mock `weather.requests` (where the name is *used*). Testing `get_temp_c` through the real `requests` call is what catches the wrong-field bug; `classify`/`to_fahrenheit` can mock either layer.

```python
# test_weather.py
import pytest
from unittest.mock import patch
import weather


# ── get_temp_c: mock requests so the REAL parsing logic runs ────────────────
def test_get_temp_c_parses_temp_c_field():
    with patch("weather.requests") as mock_requests:
        mock_requests.get.return_value.json.return_value = {"temp_c": 21}
        assert weather.get_temp_c("london") == 21
        mock_requests.get.assert_called_once_with(
            "https://api.example.com/weather/london"
        )


# ── classify: patch get_temp_c directly to feed boundary temperatures ───────
@pytest.mark.parametrize("temp, expected", [
    (-5, "freezing"),
    (0,  "cold"),      # boundary — catches 'freezing uses <='
    (14, "cold"),
    (15, "mild"),      # boundary — catches 'cold uses < 16'
    (27, "mild"),
    (28, "hot"),       # boundary — catches 'hot uses <= 28'
    (35, "hot"),
])
def test_classify_boundaries(temp, expected):
    with patch("weather.get_temp_c", return_value=temp):
        assert weather.classify("anywhere") == expected


# ── to_fahrenheit ───────────────────────────────────────────────────────────
@pytest.mark.parametrize("c, f", [(0, 32.0), (100, 212.0), (37, 98.6)])
def test_to_fahrenheit(c, f):
    with patch("weather.get_temp_c", return_value=c):
        assert weather.to_fahrenheit("anywhere") == pytest.approx(f)
```

## Why this works

- **`patch("weather.requests")`** — `weather.py` did `import requests`, so the name to replace lives in the `weather` namespace. Patching `"requests.requests"` or `"requests.get"` would miss. The chained `.get.return_value.json.return_value` builds the `resp = requests.get(...)` → `resp.json()` path.
- **Testing `get_temp_c` via the `requests` mock** is the only way to catch the `wrong_field` mutant. If you had mocked `weather.get_temp_c` for *every* test, you'd never run its real body, and a bug reading `resp.json()["temp"]` would sail through. **Never mock the function you're trying to test.**
- **`classify` boundaries** — patching `get_temp_c` directly is fine here, because `classify`'s own logic is what's under test. The boundary values `0`, `15`, `28` are exactly where the `<` vs `<=` mutants bite.
- **`pytest.approx` for Fahrenheit** — `37 * 9/5 + 32 == 98.60000000000001` in floating point; `== 98.6` would fail. Always `approx` floats.

## The network block

The verifier installs an autouse fixture that makes `socket.socket` raise. Any test that *didn't* mock would try to open a real connection and die with `RuntimeError: real network access in a test`. This is a pattern worth stealing for your own `conftest.py` — it turns "oops, a test hit production" from a silent flake into an immediate, obvious failure.

## When NOT to mock (the balance)

These are fast, deterministic unit tests — exactly right for logic and parsing. But they prove your code works *against a mock you wrote*, not against the real API. In a real project you'd keep **one** integration test (marked `@pytest.mark.integration`, run separately) that hits a sandbox endpoint or a recorded response, so you'd notice if the real API changed its field from `temp_c` to something else. Mock for the many fast tests; keep a thin real-boundary test for honesty.
