# Encryption: At Rest, In Transit & Envelope

> **Module 04 · Course 31** — Most engineers can say "we use AES-256 and TLS." Few can explain why using the same key for a billion records is dangerous, what a nonce is and what happens when it repeats, or why rotating a KMS key doesn't re-encrypt your data. This module fills those gaps: the primitives, envelope encryption (the actual architecture used by every cloud KMS), TLS from the certificate down to the handshake, and the failure modes that cause real breaches.

You do not need a cryptography background — you need to understand the *contracts* that the primitives give you and the *mistakes* that void them. This module covers both.

---

## Symmetric vs Asymmetric Encryption

Both exist because neither is unconditionally better.

### Symmetric

One key encrypts and decrypts. Algorithms: AES (standard block cipher), ChaCha20 (stream cipher, faster on constrained hardware).

```
encrypt: AES-256-GCM(plaintext, key, nonce) → ciphertext + auth_tag
decrypt: AES-256-GCM(ciphertext + auth_tag, key, nonce) → plaintext (or auth failure)
```

Fast (AES-NI hardware instruction on modern CPUs: ~10 GB/s). The problem: both parties need the same key. Securely distributing that key to many parties without a secure channel is the key distribution problem — and the answer to that is asymmetric encryption.

### Asymmetric

Two mathematically linked keys: a **public key** (safe to publish) and a **private key** (never shared). What one encrypts, only the other can decrypt. Algorithms: RSA, ECDH, Ed25519.

```
encrypt: RSA_OAEP(plaintext, recipient_public_key) → ciphertext
decrypt: RSA_OAEP(ciphertext, recipient_private_key) → plaintext
```

Slow compared to symmetric (1000x slower for bulk data). Used for the key distribution problem, not for encrypting large payloads.

### The hybrid pattern

In practice, every real system uses both:

```
1. Generate a random symmetric key (the session key / DEK)
2. Encrypt the payload with the symmetric key (fast)
3. Encrypt the symmetric key with the recipient's public key (slow, but the key is tiny)
4. Send: encrypted key + ciphertext
5. Recipient decrypts the key with their private key, then decrypts the payload
```

This is TLS, PGP, Signal, and every KMS implementation under the hood.

---

## Envelope Encryption: DEK / KEK / KMS

Envelope encryption is the standard architecture for encrypting data at scale. It solves a critical problem: if you encrypt every record with the same key, rotating that key means re-encrypting every record. Envelope encryption avoids this.

```
┌──────────────────── Envelope Encryption ─────────────────────┐
│                                                               │
│  Data Encryption Key (DEK)  — a random key generated per     │
│                               record (or per file / batch)    │
│            │                                                  │
│            ▼                                                  │
│  plaintext ──► AES-256-GCM(DEK) ──► ciphertext               │
│                                                               │
│  Key Encryption Key (KEK)   — lives in KMS, never on disk    │
│            │                                                  │
│            ▼                                                  │
│  DEK ──► KMS.Encrypt(KEK) ──► encrypted_DEK                  │
│                                                               │
│  Store: { ciphertext, encrypted_DEK }                         │
│  (the plaintext DEK is discarded after use)                   │
│                                                               │
│  To decrypt:                                                  │
│  encrypted_DEK ──► KMS.Decrypt(KEK) ──► DEK                  │
│  DEK + ciphertext ──► AES-256-GCM ──► plaintext              │
└───────────────────────────────────────────────────────────────┘
```

### Why this is better than encrypting with the KEK directly

| Property | Encrypt-all-with-KEK | Envelope (DEK+KEK) |
|----------|---------------------|-------------------|
| Key rotation | Re-encrypt every record | Re-encrypt only the DEKs (tiny) |
| Blast radius of a compromised record | KEK decrypts every record | Only the one DEK |
| KMS call cost | One KMS call per read/write | One KMS call per DEK issue (DEK can be cached for a session) |
| Parallel encryption | Can't parallelize one key | Each record has its own DEK — fully parallel |

### Key rotation without re-encrypting data

This is the sleight of hand that makes KMS rotation practical:

```
Before rotation:
  record.ciphertext = AES(plaintext, DEK)
  record.encrypted_dek = KMS.Encrypt(DEK, KEK_v1)

After KEK rotation to v2:
  record.encrypted_dek = KMS.Encrypt(DEK, KEK_v2)   ← only this changes
  record.ciphertext is unchanged

The DEK and the plaintext are never touched.
```

AWS KMS, GCP Cloud KMS, and HashiCorp Vault's transit engine all implement this pattern. The key rotation is a re-wrap of the DEK, not a re-encryption of the data.

---

## TLS: What the Certificate Actually Proves

TLS combines asymmetric encryption (for key exchange) and symmetric encryption (for the session). The certificate's job is to bind an identity to a public key and get a trusted third party (the CA) to sign that binding.

```
Certificate fields that matter:
  Subject:       CN=postgres.dojo-app.svc  ← who this cert is for
  SAN:           DNS:postgres.dojo-app.svc, IP:10.96.0.5
  Issuer:        CN=dojo-ca               ← who signed it
  Not Before/After: 2024-01-01 / 2025-01-01  ← validity window
  Public Key:    the server's public key
  Signature:     CA's signature over all of the above
```

The handshake in one paragraph: client presents the server's cert chain to its trust store, verifies the CA signature, checks that the SAN matches the hostname it connected to, checks the validity window, and checks the CRL/OCSP (not revoked). If all pass, the client trusts the public key in the cert. Both parties then use that public key to agree on a symmetric session key (via ECDH key agreement in TLS 1.3) and the rest of the connection is AES-GCM.

### mTLS: Mutual Authentication

Standard TLS only authenticates the server. In a zero-trust network, both parties authenticate:

```
Client ──► "here is my certificate" ──► Server
Client ◄── "here is my certificate" ◄── Server
(both verify the other's cert against their trust store)
```

mTLS is the mechanism behind SPIFFE/SPIRE, Istio service mesh, and Vault's PKI engine. Each workload gets a short-lived certificate encoding its identity (SPIFFE ID: `spiffe://cluster.local/ns/dojo-app/sa/app-sa`) and presents it to every peer.

---

## Where Each Mechanism Applies

```
┌─────────────────────────────────────────────────────────────────┐
│ Encryption at rest                                              │
│   etcd:         EncryptionConfiguration (AES-CBC / KMS)        │
│   disk:         LUKS / dm-crypt / cloud disk encryption        │
│   backups:      backup encryption key managed separately        │
│                                                                 │
│ Encryption in transit                                           │
│   service→service:   TLS (mutual or one-way)                    │
│   user→cluster:      TLS (kubectl uses client cert auth)        │
│   Vault→client:      TLS + Vault token                          │
│                                                                 │
│ Envelope encryption                                             │
│   application data:  DEK per record, KEK in KMS                 │
│   Kubernetes etcd:   API server as KMS client (KMS provider)   │
│   Vault transit:     DEK wrapping on demand                     │
│                                                                 │
│ Asymmetric signing (not encryption)                             │
│   image signing:     cosign / Notary (key in KMS or Sigstore)  │
│   sealed-secrets:    controller's RSA key seals the DEK         │
│   JWT tokens:        RS256 / ES256 signature on claims          │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Management Mistakes

### Mistake 1: Storing the KEK alongside the DEK

```
# wrong: both key and ciphertext on same disk
/data/records.enc   ← encrypted with DEK
/data/dek.key       ← plaintext DEK
/keys/kek.key       ← plaintext KEK
```

If an attacker reads the disk, they have everything. The KEK must live in a hardware-backed KMS that is never accessible as a file.

### Mistake 2: Nonce reuse

AES-GCM uses a 96-bit nonce (IV). If you encrypt two different plaintexts with the same key and the same nonce, an attacker can XOR the two ciphertexts to recover information about both plaintexts, and can also forge authentication tags. This breaks confidentiality and integrity simultaneously.

```python
# wrong: sequential counter can wrap if the counter variable overflows or resets
nonce = counter.to_bytes(12, 'big')   # if counter wraps, nonces repeat

# correct: generate a random 12-byte nonce for every encryption
import os
nonce = os.urandom(12)   # 96 bits, collision probability negligible for < 2^32 messages
```

> Vault's transit engine handles nonce generation internally — you never touch it. When you implement envelope encryption yourself (Module 04 challenge), use `os.urandom(12)` every time, never a counter.

### Mistake 3: Using ECB mode

AES in ECB (Electronic Code Book) mode encrypts each 16-byte block independently with the same key. Identical plaintext blocks produce identical ciphertext blocks. The structure of the data is visible in the ciphertext.

Use AES-GCM (authenticated encryption — confidentiality + integrity) or AES-CBC with HMAC. Never ECB for anything that isn't a single 16-byte block.

### Mistake 4: Deriving a key from a password without a KDF

```python
# wrong: raw hash of a password as an encryption key
import hashlib
key = hashlib.sha256(b'password123').digest()  # fast, brute-forceable

# correct: use a KDF designed for password-based key derivation
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
import os
salt = os.urandom(16)
kdf = Scrypt(salt=salt, length=32, n=2**14, r=8, p=1)
key = kdf.derive(b'password123')   # slow by design
```

### Mistake 5: Symmetric key length mismatch

AES-128 is computationally secure today. AES-256 provides a larger margin. The key must be the right length for the cipher (16 bytes for AES-128, 32 bytes for AES-256). Truncating or padding a key is a bug, not a workaround.

---

## Debugging Encryption Failures

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `DecryptionError: authentication tag mismatch` | Ciphertext was modified (bit flip, truncation) or wrong key used | Check key selection logic; verify data integrity (checksum before decrypt); confirm nonce is stored alongside ciphertext |
| `ValueError: nonce is required` / wrong nonce length | Nonce not stored with ciphertext or wrong size | Always store nonce prepended to or alongside ciphertext; for AES-GCM use 12 bytes |
| Data loss after KMS key rotation | Old ciphertext still encrypted with old key version, old version deleted | Never delete a KMS key version while data encrypted with it exists; add a retention policy; re-wrap DEKs before disabling old versions |
| TLS: `x509: certificate has expired or is not yet valid` | Cert expired, or clock skew between client and server | Renew cert; check `openssl x509 -noout -dates -in cert.pem`; verify NTP sync |
| TLS: `x509: certificate is valid for X, not Y` | SAN doesn't match the hostname the client connected to | Issue new cert with correct SAN; or fix the client to use the canonical hostname |
| TLS: `x509: certificate signed by unknown authority` | Client's trust store doesn't have the CA | Add the CA cert to the trust bundle; or use a well-known CA (Let's Encrypt) |
| mTLS: server rejects client cert with `bad certificate` | Client cert expired, wrong CA, or mTLS not enabled on server | Check `openssl s_client -connect ... -cert client.pem -key client.key`; check server's `ClientAuth` config |
| `InvalidCiphertextException` from AWS KMS | Wrong KMS key ID, cross-region call, or key disabled | Check the key ID in the ciphertext metadata; `aws kms describe-key --key-id <id>` |

### Inspecting a certificate

```bash
# check expiry and SAN
openssl x509 -noout -text -in cert.pem | grep -E 'Not (Before|After)|Subject Alternative'

# check from a live server
echo | openssl s_client -connect postgres.dojo-app.svc:5432 -starttls postgres 2>/dev/null \
  | openssl x509 -noout -dates

# check cert chain validity
openssl verify -CAfile ca.pem cert.pem
```

### Diagnosing a lost KEK

```bash
# attempt to decrypt with Vault transit — if the key version is deleted:
vault write transit/decrypt/app-data ciphertext="vault:v1:..."
# Error: error:1e08010c:CIPHER routines:EVP_EncryptInit_ex2:initialization error
# (or: key version not found)

# check which key versions exist
vault read transit/keys/app-data
# min_decryption_version, min_encryption_version, latest_version

# check if a version was deleted
vault list transit/keys/
```

If the KEK (the Vault key or KMS CMK) is deleted while data is still encrypted with it, **the data is unrecoverable**. The only protection is:

1. Never delete a key version while data encrypted with it exists.
2. Configure a deletion protection policy on the KMS key (AWS: key deletion 7–30 day waiting period; GCP: planned key destruction; Azure: soft-delete + purge protection).
3. Maintain an out-of-band backup of DEKs encrypted with an offline copy of the KEK for disaster recovery.

> **War story.** A small SaaS company accidentally deleted their GCP Cloud KMS key during a Terraform refactor — the key ID was referenced by a data block that resolved to a different key in a new project. Their entire customer database was encrypted with DEKs that were wrapped by the deleted KMS key. They had regular database backups. The backups were encrypted. Without the KEK, the backups were binary noise. GCP's key deletion has a 24-hour grace period; they submitted a support request within that window and GCP restored the key. The 24-hour race cost one CTO a sleepless night and the company a major incident report to every enterprise customer. The lesson: test your KMS key deletion policy before a human fat-fingers it, and know exactly which KMS keys encrypt which data.

---

## Envelope Encryption in Python (What the Challenge Implements)

The challenge for this module has you implement envelope encryption end-to-end using the Python `cryptography` library. Here is the reference architecture you are implementing against:

```python
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import os

def encrypt_record(plaintext: bytes, kek: bytes) -> dict:
    # 1. Generate a fresh DEK for this record
    dek = os.urandom(32)          # AES-256 key, 32 bytes
    nonce_data = os.urandom(12)   # GCM nonce, 12 bytes

    # 2. Encrypt plaintext with the DEK
    aesgcm = AESGCM(dek)
    ciphertext = aesgcm.encrypt(nonce_data, plaintext, None)

    # 3. Encrypt (wrap) the DEK with the KEK
    kek_nonce = os.urandom(12)
    kek_aesgcm = AESGCM(kek)
    encrypted_dek = kek_aesgcm.encrypt(kek_nonce, dek, None)

    # 4. Store everything needed to decrypt — except the plaintext DEK
    return {
        "ciphertext": ciphertext,
        "nonce": nonce_data,
        "encrypted_dek": encrypted_dek,
        "kek_nonce": kek_nonce,
    }

def decrypt_record(envelope: dict, kek: bytes) -> bytes:
    # 1. Unwrap the DEK using the KEK
    kek_aesgcm = AESGCM(kek)
    dek = kek_aesgcm.decrypt(envelope["kek_nonce"], envelope["encrypted_dek"], None)

    # 2. Decrypt the ciphertext using the DEK
    aesgcm = AESGCM(dek)
    return aesgcm.decrypt(envelope["nonce"], envelope["ciphertext"], None)
```

The challenge adds KEK rotation: given a set of envelopes encrypted with `kek_v1`, re-wrap the DEKs with `kek_v2` without touching the ciphertext.

---

## Checkpoint

You are ready for the challenges when you can:

1. Explain the key distribution problem and why asymmetric encryption solves it for symmetric key exchange.
2. Describe the hybrid encryption pattern used by TLS in one paragraph.
3. Define DEK and KEK; explain why envelope encryption makes key rotation cheap.
4. State what happens to existing ciphertext when a KEK is rotated (hint: it doesn't change).
5. Explain why nonce reuse in AES-GCM breaks both confidentiality and integrity.
6. State the correct nonce generation approach and the nonce size for AES-GCM.
7. Explain what a TLS certificate proves and what the CA's signature binds together.
8. Describe how mTLS differs from one-way TLS and name one system that uses it in Kubernetes.
9. State the consequence of deleting a KMS key version while DEKs wrapped with it are in the database.
10. Explain how to verify that etcd encryption is actually using the new provider after enabling `EncryptionConfiguration`.

➡ You have completed the four foundational modules for Secrets & Zero Trust. The challenges in this course will have you implement each concept hands-on: from scanning for leaked credentials and exploiting an unrotated API key, to wiring ESO to Vault, implementing envelope encryption, and verifying etcd encryption is real — not just configured.
