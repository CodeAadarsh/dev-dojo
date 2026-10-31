# Solution — TOTP MFA from Scratch

## Complete `totp.py`

```python
import hmac
import hashlib
import struct
import base64


def generate(secret: str, at_time: float) -> str:
    key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    counter = struct.pack(">Q", int(at_time) // 30)
    digest = hmac.new(key, counter, hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code_int = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(code_int % 10**6).zfill(6)


def verify(secret: str, code: str, at_time: float, used_codes: set) -> bool:
    if code in used_codes:
        return False
    step = int(at_time) // 30
    for delta in (-1, 0, 1):
        candidate_time = float((step + delta) * 30)
        if generate(secret, candidate_time) == code:
            return True
    return False
```

## Why each piece is correct

### Base32 decoding with padding

`base64.b32decode` is strict about padding — it requires the input length to be a multiple of 8. Most QR-code secrets omit trailing `=` signs, so `secret.upper() + "=" * (-len(secret) % 8)` adds exactly the right amount. The `upper()` handles libraries that store secrets in lowercase.

### Counter as big-endian uint64

RFC 6238 §4 requires the counter to be an 8-byte unsigned integer in network byte order. `struct.pack(">Q", ...)` is exactly that. `int(at_time) // 30` truncates rather than rounds — truncation is the spec behaviour.

### Dynamic truncation

The last byte of the HMAC digest determines the 4-byte window. Masking with `0x0F` keeps offset in [0, 15], leaving at least 4 bytes before the 20-byte digest ends. Masking the extracted int with `0x7FFFFFFF` (31 bits) strips the sign bit so the value is always positive under any 32-bit signed integer interpretation.

### Replay protection

`verify()` checks `used_codes` *before* computing anything. This matters: if the code is in `used_codes`, no HMAC is computed and there is no timing oracle on the secret. The caller appends to `used_codes` after a `True` return — this keeps the policy (what counts as "used") out of the crypto primitive, which is the right separation.

### The ±1 window loop

Iterating `(-1, 0, 1)` and multiplying by 30 to reconstruct the representative timestamp handles the edge: at the boundary of a 30-second step, both the outgoing and incoming step are within a single clock-skew interval. The loop short-circuits on the first match — no need to check the remaining deltas.

## Attacker's view

An attacker who intercepts one valid TOTP code gets at most 30–90 seconds of usefulness (the window). Without replay protection that widens to the full window width. With proper server-side replay tracking (this challenge implements the client side of that contract), a stolen code is useless after one use. This is why TOTP replaces password-only login rather than supplementing it with a *static* second factor.

## Verify

```bash
bash courses/course-16-security-auth/challenges/04-totp-mfa/verify.sh
```
