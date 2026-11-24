# Solution: Image Signing

## Step 1: Install cosign

```bash
# macOS
brew install cosign

# Linux (download the binary)
LATEST=$(curl -s https://api.github.com/repos/sigstore/cosign/releases/latest | grep tag_name | cut -d'"' -f4)
curl -LO "https://github.com/sigstore/cosign/releases/download/${LATEST}/cosign-linux-amd64"
chmod +x cosign-linux-amd64
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
```

## Step 2: Generate a key pair

```bash
cosign generate-key-pair
# Enter passphrase (or press Enter for none in a lab):
# Writes: cosign.key (private), cosign.pub (public)
```

Keep `cosign.key` private. `cosign.pub` is what verifiers use to check signatures.

## Step 3: Sign the image

```bash
COSIGN_INSECURE_IGNORE_TLOG=true cosign sign \
  --key cosign.key \
  --allow-insecure-registry \
  localhost:5001/dojo/api:1.0
```

What happens under the hood:
1. cosign resolves the tag to a digest: `localhost:5001/dojo/api@sha256:abc123...`
2. It creates a signature payload: `{"critical":{"image":{"docker-manifest-digest":"sha256:abc123..."},...}}`
3. It signs the payload with your private key (ECDSA-P256)
4. It pushes the signature as a new OCI artifact to the registry: `localhost:5001/dojo/api:sha256-abc123....sig`

## Step 4: Verify the signature

```bash
COSIGN_INSECURE_IGNORE_TLOG=true cosign verify \
  --key cosign.pub \
  --allow-insecure-registry \
  localhost:5001/dojo/api:1.0
```

You should see output like:

```json
[{"critical":{"identity":{"docker-reference":"localhost:5001/dojo/api"},...},"optional":null}]
```

## Step 5: Annotate the Deployment

```bash
kubectl annotate deployment api \
  dojo.docker/signed=true \
  -n dojo-docker-signing
```

## Why digest-based signing provides tamper-evidence

The signature is bound to the **image digest** (sha256 of the manifest), not the tag. If someone pushes a different image under the same `api:1.0` tag:

```
Before: api:1.0 → sha256:abc123 (signed by you)
Attack: api:1.0 → sha256:xyz999 (attacker's image, different digest)
```

Verification fails:

```bash
cosign verify --key cosign.pub --allow-insecure-registry localhost:5001/dojo/api:1.0
# Error: no matching signatures
```

The attacker's image has digest `sha256:xyz999`. There is no signature for that digest. The swap is detected.

## Integrating into CI/CD

In production, sign during build, verify during deploy:

```yaml
# In your CI pipeline (after docker push):
- name: Sign image
  run: |
    cosign sign --key ${{ secrets.COSIGN_KEY }} $IMAGE_REF

# In your deployment admission webhook or policy engine:
# Deny pods whose image digest has no valid cosign signature
```

Policy engines like Kyverno and OPA Gatekeeper have cosign verification built in — you can block unsigned images at the admission level, before the kubelet even tries to pull them.
