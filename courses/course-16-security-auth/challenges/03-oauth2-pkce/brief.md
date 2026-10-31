# OAuth2 PKCE

A security review on your OAuth2 authorization-code flow found this note in the code:

> **MEDIUM — Authorization-code interception**
> No PKCE. On a mobile/SPA client, the authorization code travels through redirect URIs. Without PKCE, a malicious app registered on the same device can intercept the code and exchange it for tokens — even without your client_secret, because public clients don't have one.

PKCE (Proof Key for Code Exchange, RFC 7636) closes this: the client proves it is the same party that started the flow by binding a one-time secret to the code.

## Context

`setup.sh` plants a starter module and a visible sample test:

```
~/.kube-dojo-work/03-oauth2-pkce/
├── pkce.py          # generate_code_verifier / generate_code_challenge / verify_pkce stubs
└── tests/
    └── test_sample.py
```

## Prerequisites

```bash
pip install pytest argon2-cffi pyjwt pyotp
```

## Mission

Implement three functions in `pkce.py`:

### `generate_code_verifier() -> str`

Generate a cryptographically random `code_verifier` per RFC 7636 §4.1:
- Length: 43–128 characters (use 64 for simplicity).
- Character set: `[A-Z a-z 0-9 - . _ ~]` (unreserved URI chars).
- Use `secrets.token_urlsafe(48)` — it already produces URL-safe base64 without padding, which satisfies the character set.

### `generate_code_challenge(code_verifier: str) -> str`

Derive the S256 `code_challenge` per RFC 7636 §4.2:

```
code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))
```

BASE64URL means standard base64 with `+→-`, `/→_`, and **no `=` padding**.

In Python:
```python
import hashlib, base64
digest = hashlib.sha256(code_verifier.encode("ascii")).digest()
challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
```

### `verify_pkce(code_verifier: str, code_challenge: str) -> bool`

The authorization server calls this when the client POSTs the token request.
Re-derive the challenge from the verifier and compare. Return `True` if they match, `False` otherwise.

## The flow (one full round-trip)

```
Client                          Authorization Server
  |                                     |
  | 1. generate_code_verifier()         |
  |    generate_code_challenge(v) -> c  |
  |                                     |
  | 2. GET /authorize?code_challenge=c  |
  |    &code_challenge_method=S256 ---> |
  |                                     |  (server stores c, issues code)
  | <--- redirect with ?code=xyz        |
  |                                     |
  | 3. POST /token                      |
  |    code=xyz                         |
  |    code_verifier=v             ---> |
  |                                     |  verify_pkce(v, stored_c)?
  |                                     |  yes -> issue access_token
  | <--- access_token + refresh_token   |
```

An interceptor who steals `code=xyz` at step 2 cannot complete step 3 — they don't know `v`, and they cannot reverse SHA256 to recover it from `c`.

## The hidden verifier checks

1. `generate_code_verifier()` returns at least 43 characters.
2. `generate_code_challenge(v)` matches the manual S256 derivation.
3. `verify_pkce(v, c)` returns `True` when `c` was derived from `v`.
4. `verify_pkce(v, wrong_c)` returns `False` for a mismatched challenge.
5. `verify_pkce(tampered_v, c)` returns `False` when the verifier was modified.
6. Two calls to `generate_code_verifier()` produce different values (randomness check).
7. The challenge contains only URL-safe base64 characters (no `+`, `/`, or `=`).

## Verify

```bash
bash courses/course-16-security-auth/challenges/03-oauth2-pkce/verify.sh
```

All tests green → flag printed.
