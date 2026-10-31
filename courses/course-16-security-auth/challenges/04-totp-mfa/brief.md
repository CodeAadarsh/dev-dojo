# TOTP MFA from Scratch

A security audit finding lands in your inbox: *"The staging login still accepts static passwords. Engineering committed to ship TOTP-based MFA before Q3. RFC 6238 compliance is required. Auth library is off the table — vendoring it adds 3 years of patch surface. Implement it from the standard library."*

## Background

TOTP (Time-based One-Time Password, [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238)) is what your authenticator app implements. The algorithm is deceptively small:

1. Divide the current Unix time by 30 to get a **counter** (time step).
2. HMAC-SHA1 the counter (big-endian 8-byte integer) with the shared secret.
3. **Dynamic truncation**: use the last nibble of the digest as an offset; take 4 bytes from that offset; mask to 31 bits.
4. Modulo 10⁶ → 6-digit code, zero-padded.

The secret is a **base32-encoded** string (what a QR code embeds). The standard library has `hmac`, `hashlib`, `struct`, and `base64` — no third-party deps needed.

A ±1 step window (accepting the previous, current, and next 30-second code) is mandatory in RFC 6238 §5.2 to tolerate clock skew. Replay protection means a code that has already been verified must be rejected even if it is still within the window.

## Work directory layout

`setup.sh` plants a skeleton in your work directory:

```
~/.kube-dojo-work/04-totp-mfa/
├── totp.py          # implement generate() and verify() here
└── tests/
    └── test_totp_sample.py   # visible sample tests (3 of the hidden suite)
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-totp-mfa
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Open `totp.py` and implement the two functions:

```python
def generate(secret: str, at_time: float) -> str:
    """Return the 6-digit TOTP code for the given secret at at_time (Unix seconds)."""

def verify(secret: str, code: str, at_time: float, used_codes: set) -> bool:
    """
    Return True if code is valid for secret at at_time with a +-1 step window,
    AND code has not appeared in used_codes (replay protection).
    Callers are responsible for adding accepted codes to used_codes.
    """
```

`used_codes` is a `set` the caller owns and mutates — your `verify()` must only *read* it (never `.add()`). The caller adds to it after a True return. This keeps the API composable and lets the hidden tests control replay state precisely.

### Exact conditions the hidden verifier checks

| Test | What it asserts |
|------|-----------------|
| RFC 6238 test vector T=59 | `generate("JBSWY3DPEHPK3PXP", 59.0)` == `"287082"` |
| RFC 6238 test vector T=1111111109 | `generate("JBSWY3DPEHPK3PXP", 1111111109.0)` == `"081804"` |
| Window — previous step accepted | code from `at_time - 30` is valid at `at_time` |
| Window — next step accepted | code from `at_time + 30` is valid at `at_time` |
| Window — two steps back rejected | code from `at_time - 60` is NOT valid |
| Replay rejection | the same valid code passed to `verify` twice with an already-populated `used_codes` returns False |
| Wrong code rejected | a deliberately wrong code returns False |

> RFC test vectors use the ASCII secret `"12345678901234567890"` base32-encoded. The helper `base64.b32encode(b"12345678901234567890").decode()` gives `"GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"`. The vector secret `"JBSWY3DPEHPK3PXP"` decodes to `b"Hello!"`. Pinning which secret each vector uses prevents confusion.

## Why it matters

Every TOTP library in your stack is a dependency you own at patch time. Understanding the raw algorithm means you can audit those libraries (and spot bugs like [CVE-2023-49208](https://nvd.nist.gov/vuln/detail/CVE-2023-49208) — a timing side-channel in a popular Python TOTP package). Beyond auditing, TOTP is the simplest example of a **shared-secret protocol** — the same HMAC-counter pattern shows up in HOTP, WebAuthn backup codes, and API signature schemes.

## Verify

```bash
bash courses/course-16-security-auth/challenges/04-totp-mfa/verify.sh
```

All hidden tests green → flag printed.
