# MFA & Passwordless

> **Module 05 · Course 16** — A password is a single point of compromise. MFA degrades that to a two-point compromise. Passwordless eliminates the password entirely and replaces it with a cryptographic proof that is phishing-resistant by construction. This module covers how all three layers actually work at the protocol level, where each one's defenses end, and what a production hardening decision looks like when you're choosing between them.

The framing: MFA factors are commonly described as "something you know, have, or are." The more useful frame for an SDE is: "how much does it cost an attacker to bypass this factor remotely?" — which is the real measure of phishing resistance.

---

## TOTP — Time-Based One-Time Passwords (RFC 6238)

TOTP is the algorithm behind every "open your authenticator app" prompt. It is HMAC-based OTP (HOTP, RFC 4226) with time as the moving counter.

### How TOTP is computed

The TOTP algorithm in one equation:

```
TOTP(K, t) = HOTP(K, floor(epoch_seconds / step))
HOTP(K, C)  = Truncate(HMAC-SHA1(K, C)) mod 10^digits
```

Where:
- `K` is the shared secret (80-bit random, base32-encoded, used to seed the authenticator)
- `t` is the current Unix timestamp
- `step` is the time window (30 seconds by default, per RFC 6238)
- `digits` is the output length (6 by default)

The `Truncate` step: take the HMAC-SHA1 output (20 bytes), pick a dynamic offset from the last nibble of byte 19, extract 4 bytes from that offset, mask to 31 bits, take mod 10^6.

What this means in practice: every 30 seconds, both the user's authenticator and your server compute the same 6-digit code from the same shared secret. No network call needed; it's pure math. Validation allows ±1 window (±30 seconds) of clock drift.

```python
import hmac, hashlib, struct, time, base64

def totp(secret_b32: str, step: int = 30, digits: int = 6) -> str:
    key = base64.b32decode(secret_b32.upper())
    counter = int(time.time()) // step
    msg = struct.pack(">Q", counter)
    h = hmac.new(key, msg, hashlib.sha1).digest()
    offset = h[19] & 0x0F
    code = struct.unpack(">I", h[offset:offset+4])[0] & 0x7FFFFFFF
    return str(code % (10 ** digits)).zfill(digits)

def verify_totp(secret_b32: str, submitted: str, drift_windows: int = 1) -> bool:
    key = base64.b32decode(secret_b32.upper())
    counter = int(time.time()) // 30
    for delta in range(-drift_windows, drift_windows + 1):
        msg = struct.pack(">Q", counter + delta)
        h = hmac.new(key, msg, hashlib.sha1).digest()
        offset = h[19] & 0x0F
        code = struct.unpack(">I", h[offset:offset+4])[0] & 0x7FFFFFFF
        if str(code % 1_000_000).zfill(6) == submitted:
            return True
    return False
```

### TOTP enrollment

Enrollment gives the user the shared secret K. The standard delivery is a QR code encoding a `otpauth://` URI:

```
otpauth://totp/Corp:aadarsh@corp.com?secret=BASE32SECRET&issuer=Corp&algorithm=SHA1&digits=6&period=30
```

The server generates K with `secrets.token_bytes(20)` (160 bits for SHA-1 HMAC), base32-encodes it, stores it hashed (like a password — if your TOTP secrets table is leaked, every account is compromised), and renders the QR code once. The user must see the code verify successfully before enrollment is complete — this prevents storing an incorrectly scanned secret.

### HOTP — the counter-based variant

HOTP uses a monotonic counter instead of time. Each OTP is single-use: the server increments the counter on successful verification. The authenticator increments on button press. They can drift (user presses without submitting); the server allows a lookahead window (typically 10) to resync.

HOTP is less common than TOTP because desync is a real user-support burden — but it matters when you can't trust the client clock (hardware tokens, offline devices).

---

## Push & SMS Risks

Push-based MFA (Okta Verify, Duo Push, Microsoft Authenticator) sends a notification to the user's enrolled phone: "Approve this login?" The user taps Approve. It's more usable than TOTP because there's no code to type.

The attack: **MFA fatigue**. An attacker who has stolen the password sends repeated authentication requests (legitimate push notifications) at 2 am until the user taps Approve to make it stop. This is not theoretical — it was the exact technique used in the 2022 Uber breach.

The defense: push with **number matching**. The push notification displays a 2-3 digit number. The user must confirm that the number on their screen matches the number in the notification. This requires the attacker to be in a real-time active phishing session with the user — dramatically harder than blind fatigue.

**SMS OTP** is the weakest second factor in widespread use:

| Attack vector | Description |
|--------------|-------------|
| SIM swap | Attacker convinces the carrier to port the number to their SIM |
| SS7 interception | Nation-state-level interception of the telecom backbone |
| Real-time phishing | Attacker proxies the login and relays the SMS code before it expires |
| Malware | Banking trojans intercept SMS messages on Android |

SMS OTP satisfies regulatory checkbox MFA requirements (PCI DSS, SOC 2) but is phishable in real-time by a motivated attacker. For any sensitive surface (admin consoles, production deployments, financial actions), use TOTP at minimum, or WebAuthn.

> **The NIST position.** NIST SP 800-63B deprecated SMS OTP as a valid authenticator type for new systems in 2017, specifically citing SS7 vulnerabilities. Banks and enterprises continue to use it because migration is expensive, not because NIST changed its mind.

---

## WebAuthn & Passkeys (FIDO2)

WebAuthn is the W3C standard that enables a browser or native app to authenticate using a public-key credential — a passkey. The key never leaves the device. Phishing is structurally impossible because the credential is bound to the origin.

### The three actors

```
┌─────────────────┐        ┌───────────────────────────┐        ┌───────────────┐
│  Authenticator  │        │  Client (browser / app)   │        │  Relying      │
│  (device TPM,   │◀──────▶│  WebAuthn JS API           │◀──────▶│  Party (RP)   │
│   YubiKey,      │        │  navigator.credentials    │        │  your server  │
│   platform key) │        └───────────────────────────┘        └───────────────┘
```

The key hierarchy:
- Each authenticator has a device-level root key (burned in at manufacture, never exported)
- Per-origin credential keys are derived from or stored on that root
- The RP gets only the **public key**; the matching private key never leaves the authenticator

### Registration flow

```
1. RP generates a challenge (32 random bytes) and sends options to the client
2. Browser calls navigator.credentials.create({publicKey: options})
3. Authenticator:
   a. user gesture (biometric / PIN / touch)
   b. generates a key pair (P-256 or Ed25519 typically)
   c. returns attestation = {credentialId, publicKey, attestationObject}
   d. attestationObject contains clientDataJSON (challenge, origin, type)
      signed by the authenticator's attestation key
4. RP verifies:
   - challenge matches what was issued
   - origin = RP's origin (e.g. https://app.corp.com)
   - rpIdHash = SHA-256(RP ID, defaults to origin's registrable domain)
   - attestation signature if attestation is requested
5. RP stores credentialId + publicKey + counter
```

### Authentication flow

```
1. RP generates a new challenge; client calls navigator.credentials.get()
2. Authenticator signs the assertion:
   assertion = {credentialId, authenticatorData, clientDataJSON, signature}
   signature = sign(private_key, authenticatorData || SHA-256(clientDataJSON))
3. RP verifies:
   - challenge matches
   - origin matches
   - rpIdHash matches
   - signature verifies against stored public_key
   - counter > stored counter (replay detection)
4. Counter mismatch → possible cloned credential → refuse + flag for review
```

### Attestation

Attestation is optional metadata proving the authenticator is a specific model of genuine hardware. The attestation certificate chain (from the authenticator manufacturer) lets the RP know whether it's talking to a FIPS-certified hardware key, a platform TPM, or a software credential. Most enterprise deployments verify that enrolled credentials come from approved authenticator models (e.g., YubiKey 5 series only).

### Resident keys / discoverable credentials

Standard WebAuthn credentials require the RP to pass the stored `credentialId` in the `allow list` during authentication — meaning the user must first identify themselves (enter a username) so the RP can look up their credentials. Resident keys (discoverable credentials) store the full credential on the device indexed by RP ID, enabling **username-less flow**: no email address entered, just a biometric prompt.

Passkeys (the consumer branding of resident credentials synced via iCloud Keychain / Google Password Manager) are resident credentials. The distinction matters for threat model: a synced passkey can be accessed from a new device via cloud sync; a hardware-bound resident key on a YubiKey cannot — choose based on your recovery and loss scenarios.

---

## Magic Links

Magic links are a passwordless method for lower-sensitivity contexts (marketing sites, freemium products). The server generates a time-limited signed token, emails it to the user, and the user clicks the link:

```
POST /auth/magic-link  {email: "user@corp.com"}
→ server generates token = HMAC-SHA256(secret, email+expiry+jti)
→ emails link: https://app.corp/auth/verify?token=<signed>&email=<email>
→ user clicks → server verifies token, checks expiry, invalidates jti, issues session
```

Security constraints:
- Token must be single-use — store a `jti` (JWT ID or equivalent) and mark it used on first consumption.
- Expiry must be short — 15 minutes, not 24 hours.
- Transport: the link should use HTTPS; email is not end-to-end encrypted but is the same threat model as a "forgot password" link.
- Click-through link pre-fetching (Slack, Gmail) can trigger the magic link early — use `POST`-only confirmation, not a `GET` that auto-authenticates.

Magic links are phishable (an attacker can ask for one using a stolen email address, then wait for the user's inbox to be compromised), so they are appropriate for convenience authentication, not for sensitive admin actions.

---

## Recovery Codes

Recovery codes are a necessary escape hatch: if a user loses their second factor, they need a way to regain account access without making "call support and explain you lost your phone" the only path.

The standard design: 10 random 8-character alphanumeric codes, each usable exactly once. Show them at enrollment, never again. Store only the SHA-256 hash of each code.

```python
import secrets, hashlib

def generate_recovery_codes(count: int = 10) -> list[tuple[str, str]]:
    codes = []
    for _ in range(count):
        raw = secrets.token_urlsafe(8)[:10].upper()   # e.g. "A3F9X2K7P1"
        digest = hashlib.sha256(raw.encode()).hexdigest()
        codes.append((raw, digest))
    return codes  # store only digest; display only raw (once)
```

Operational considerations:
- Displaying all 10 at once lets users print/screenshot them — acceptable, that's the intent.
- Invalidate all remaining recovery codes when the user successfully enrolls a new second factor — otherwise a leaked code set remains valid indefinitely.
- Enforce rate-limiting and alerting on recovery code usage. A recovery code auth at 3 am from an unusual country is a high-confidence account takeover signal.

---

## Step-Up Authentication

Step-up auth is the practice of requiring a fresh strong authentication when a user attempts a high-risk action within an existing session. The session itself was established with username + password; the high-risk action requires re-proof of identity.

```
Normal session: password ──────────────────────────────────────────▶ read profile, search
                                                                    │
High-risk action: transfer $50k ──▶ step-up required               │
                                     re-authenticate with MFA ──────▶ approved
```

The implementation:
- Classify actions by risk level (read = low, modify = medium, financial/admin = high).
- Store the authentication context in the session: which factors were used, and when.
- Middleware checks: `if action.risk == HIGH and session.mfa_at < now - 15min: require_step_up()`.
- On step-up, record `session.mfa_at = now` and a factor identifier so you know *which* factor was used.

Step-up prevents session hijacking from being a complete game over: a stolen session cookie can read data, but cannot complete a financial transfer because it lacks a fresh MFA verification. The window (15 minutes) is a product decision; shorter is more secure, longer is less friction.

---

## Debugging MFA & Passwordless

| Symptom | Likely cause | Confirm / fix |
|---------|-------------|---------------|
| TOTP code rejected consistently | Clock drift > 30s between client and server | `date` on both sides; confirm server uses NTP; widen `drift_windows` to 2 as temporary mitigation; fix NTP |
| TOTP code rejected intermittently (first code works, second doesn't within same window) | TOTP secret stored in the DB is the decoded bytes, not the base32 string — decode mismatch | Log the base32 secret and recompute manually; re-enroll the user |
| Push MFA approved but session not created | Server-side push callback received but nonce expired (challenge too short-lived) | Extend challenge TTL to 2-3 minutes; ensure the push verification endpoint re-checks the same session nonce |
| WebAuthn `NotAllowedError` or ceremony cancelled | User dismissed the authenticator prompt; or origin mismatch (RP ID / origin mismatch) | Log `clientDataJSON.origin` vs configured `rpId`; confirm `https://` not `http://`; ensure `rpId` is a registrable domain |
| WebAuthn fails on subdomain | `rpId` set to the full FQDN instead of the registrable domain | `rpId` must be a domain suffix valid for the origin — set to `corp.com` not `app.corp.com` if you want sub-domains to share credentials |
| Counter mismatch on every authentication after a restore | Credential was cloned (or restored from backup) — counter on device is behind server's stored counter | Flag the credential for admin review; the counter mismatch is intentional — do not silently accept it |
| Magic link consumed before the user clicks it | Email client pre-fetched the URL via a link scanner | Gate the magic link on an explicit POST (a landing page with a "confirm login" button) instead of auto-authing on GET |
| SMS OTP intercepted in a real-time phishing scenario | Attacker relays credentials and OTP in realtime through a phishing proxy (Evilginx, Modlishka) | Upgrade to WebAuthn — this attack is architecturally impossible with origin-bound credentials |

> **War story.** A SaaS platform enabled WebAuthn for admins and correctly configured the `rpId` as `app.corp.com`. Three weeks later, a new staging environment launched at `staging.corp.com` and the team tried to reuse the existing enrolled credentials. Every WebAuthn authentication on staging failed with a silent `NotAllowedError`. The root cause: credentials enrolled at `app.corp.com` have `rpIdHash = SHA-256("app.corp.com")`, which doesn't match staging's `rpIdHash`. The fix was to set `rpId = "corp.com"` on production (the registrable domain) — but this required re-enrolling all existing users because stored credentials have the old `rpIdHash` burned in. The lesson: choose your `rpId` before you have users. Changing it later forces a full re-enrollment. The time to think about multi-subdomain credential sharing is before the first production passkey is enrolled, not three weeks later when there are 400 admin credentials that can't move.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain the TOTP equation `HOTP(K, floor(t/30))` — what K is, what the counter represents, and why ±1 window is the standard drift tolerance.
2. Describe the MFA fatigue attack against push-based MFA and explain how number matching breaks it.
3. Explain why SMS OTP is phishable in real time, naming the attack pattern (proxy phishing) and the protocol it exploits.
4. Walk the WebAuthn registration and authentication ceremonies step by step, naming what the RP verifies at each stage.
5. Explain the difference between attestation and assertion in WebAuthn, and when an enterprise deployment would require attestation.
6. Describe the difference between a resident key (discoverable credential) and a standard WebAuthn credential, and the implication for synced passkeys vs hardware keys.
7. Explain why magic links should only auto-authenticate on a POST (not GET) and what attack a GET-based implementation is vulnerable to.
8. Implement recovery code generation and verification in pseudocode: generation stores only the hash; verification is constant-time; used codes are marked as consumed.
9. Define step-up authentication and explain why `session.mfa_at < now - 15min` is the correct check — not just `session.mfa == true`.

➡ Next up: **Authorization & App Security** — RBAC, ABAC, ReBAC, OPA, and the OWASP hitters: XSS, SQLi, SSRF, IDOR, CORS, and secrets handling — each built in the dojo then hardened.
