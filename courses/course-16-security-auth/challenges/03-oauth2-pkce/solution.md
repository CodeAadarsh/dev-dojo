# Solution — OAuth2 PKCE

## Complete `pkce.py`

```python
import hashlib
import secrets
import base64


def generate_code_verifier() -> str:
    # token_urlsafe(48) -> 64 URL-safe chars, no padding — satisfies RFC 7636 §4.1
    return secrets.token_urlsafe(48)


def generate_code_challenge(code_verifier: str) -> str:
    digest = hashlib.sha256(code_verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def verify_pkce(code_verifier: str, code_challenge: str) -> bool:
    expected = generate_code_challenge(code_verifier)
    return expected == code_challenge
```

## Why each piece is specified by the RFC

**`secrets.token_urlsafe(48)` for the verifier.**
`token_urlsafe(n)` produces `ceil(n * 4/3)` URL-safe base64 characters from `os.urandom(n)` — for n=48 that is exactly 64 chars, well within the 43–128 range. The character set is `[A-Za-z0-9-_]` (no `+`, `/`, or `=`), which matches RFC 7636's unreserved character set. Using `random.token_hex` or `uuid4` would work length-wise but would include `-` only in UUID and would miss the entropy density of a full 384-bit random string.

**`hashlib.sha256(...).digest()` not `.hexdigest()`.**
`.hexdigest()` returns a hex string — `base64.urlsafe_b64encode` of that would produce a challenge derived from the hex representation, not the raw bytes. The RFC specifies `SHA256` over the ASCII-encoded verifier, then base64url of the raw binary digest. Using `.digest()` is the one correct path; `.hexdigest()` produces the wrong answer silently.

**`.rstrip(b"=")` strips padding.**
Standard base64 pads output to a multiple of 4 with `=`. URL-safe base64url (RFC 4648 §5 + RFC 7636 §4.2) drops the padding — the receiver knows the length from the string. PyJWT and most OAuth2 libraries expect unpadded challenges; a padded challenge will fail the known-vector test.

**`verify_pkce` uses `==` not timing-safe compare.**
For the challenge this is fine. In production you would use `hmac.compare_digest(expected, code_challenge)` to avoid timing-based oracle attacks (an attacker who can observe microsecond differences in response times could reconstruct the challenge one character at a time — unlikely in practice but trivial to prevent).

## The known-vector (RFC 7636 Appendix B)

```
verifier:  dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk
challenge: E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
```

If your `generate_code_challenge` returns anything different for that verifier, the derivation is wrong — most likely you used `.hexdigest()` or forgot to strip padding.

## Attacker's view: code interception without PKCE

On Android, multiple apps can register the same custom scheme redirect URI (e.g., `myapp://callback`). Without PKCE, the attacker's app intercepts the authorization code from the redirect and POSTs it to the token endpoint with its own (or no) client_secret. With PKCE, the token endpoint rejects the exchange: the attacker has `code` but not `code_verifier`, and cannot reverse SHA256 to produce a verifier that matches the stored challenge.

## Verify

```bash
cd ~/.kube-dojo-work/03-oauth2-pkce
bash courses/course-16-security-auth/challenges/03-oauth2-pkce/verify.sh
```
