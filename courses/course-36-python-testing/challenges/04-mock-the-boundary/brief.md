# Mock the Boundary

## The setup

`weather.py` fetches a city's temperature from an external HTTP API, then has pure logic layered on top: parse the response, classify the temperature, convert to Fahrenheit. You need to test all of that **without hitting the network** — real API calls in tests are slow, flaky, and (in the real world) cost money or rate-limit you.

To make sure you actually mock instead of quietly calling the internet, **the verifier blocks all network access**. Any test that tries to open a real socket fails with a loud error. So your tests *must* mock the boundary — and still assert strongly enough to catch every bug planted in the logic.

## The code under test

`setup.sh` plants `weather.py`:

```python
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
```

## The spec

1. `get_temp_c(city)` calls `GET {API}/{city}`, calls `raise_for_status()`, and returns the JSON field **`temp_c`**.
2. `classify` buckets the temperature: `t < 0 → "freezing"`, `0 ≤ t < 15 → "cold"`, `15 ≤ t < 28 → "mild"`, `t ≥ 28 → "hot"`. (Note the exact boundaries: `0` is cold, `15` is mild, `28` is hot.)
3. `to_fahrenheit` returns `celsius * 9/5 + 32`.

## Your mission — and the rules

Write tests in `test_weather.py` that **mock the network boundary**. Key decisions:

- **Where to patch.** `weather.py` did `import requests`, so inside that module the name is `weather.requests`. You patch **`weather.requests`**, not `requests`. (Re-read Module 05 if this is fuzzy — it's the #1 mocking bug.)
- **Test `get_temp_c` by mocking `requests`** (so its real parsing logic runs) — set up `mock_requests.get.return_value.json.return_value = {"temp_c": 21}`. This is the only way to catch a bug where it reads the wrong JSON field.
- **Test `classify` and `to_fahrenheit`** across the boundary temperatures. You can mock `weather.requests` for these too, or mock `weather.get_temp_c` directly — your choice.

The verifier runs your suite against the correct `weather.py` (must pass, with the network blocked) and against mutants with broken boundaries, a broken Fahrenheit formula, and a wrong JSON field (must fail on each).

## Verify & flag

```bash
bash courses/course-36-python-testing/challenges/04-mock-the-boundary/setup.sh
# needs requests installed: pip install pytest requests
# write tests in ~/.kube-dojo-work/04-mock-the-boundary/test_weather.py
bash courses/course-36-python-testing/challenges/04-mock-the-boundary/verify.sh
```
