# The Supply-Chain Threat Model

> **Module 01 · Course 30** — SolarWinds compromised 18,000 organizations through a build step. The xz-utils backdoor lived in an open-source dependency for two years before being caught by accident. Neither attack exploited a runtime vulnerability: the supply chain *was* the attack surface. This module maps where those attacks enter, how defenders frame them systematically, and how to locate your own chain's weakest link before an adversary does.

You already run workloads in Kubernetes. You patch CVEs. You apply RBAC policies. But "the container is secure" is not the same as "the thing *inside* the container was not tampered with on its way here." Supply-chain security asks a different question: **can you prove that what's running is what you intended to ship, with nothing added between `git commit` and `kubectl apply`?**

---

## Where attacks enter

The software supply chain has four chokepoints, each with its own threat class. An attack doesn't need to break your Kubernetes cluster — it just needs to get one malicious byte past your perimeter in something you choose to trust.

```
Developer ──→ Source / Deps ──→ Build System ──→ Registry ──→ Cluster
     │               │                │               │           │
  typosquatting  dependency      poisoned CI      image tag    admission
  confusion      confusion       build artifact   mutation     bypass
  account        account         compromised      stale image  privesc
  takeover       takeover        runner           tag reuse
```

### 1. Source and dependency phase

The code your teams write imports packages — in a modern TypeScript or Python service the transitive graph easily exceeds 1,000 nodes. Threat classes at this stage:

**Dependency confusion (namespace hijacking).** An attacker publishes a public package on npm/PyPI with the same name as your *internal* package. Package managers that check public registries before private ones pull the attacker's version. Alex Birsan demonstrated this against Microsoft, Apple, and 35+ other companies in 2021 — no exploit required, just publishing a package with a higher version number.

**Typosquatting.** Publishing `reqeusts` alongside `requests`, or `django-rest-framewrk` alongside `django-rest-framework`. In Go it's subtler — module paths like `github.com/user/go-jws` vs the real `github.com/user/go-jose`. Hit rates are 1–2% of installs, but across millions of developers that's significant.

**Maintainer account takeover.** An attacker gains write access to an existing popular package's registry account via credential stuffing or phishing, then pushes a malicious version. No name trick needed — the legitimate package name does the distribution.

### 2. Build phase

The build system is the most trusted, least audited part of the chain:

**Poisoned CI pipeline.** Injecting malicious steps into `.github/workflows`, `Jenkinsfile`, or any build DSL via a compromised developer commit or a stolen CI API token with write access.

**Compromised build artifact.** The build itself runs clean, but the resulting binary or container is post-processed before being pushed. A build runner with outbound network access can exfiltrate secrets or insert a backdoor in the artifact after the tests pass.

**The xz-utils pattern.** A carefully cultivated social engineering campaign where the attacker *becomes* a trusted maintainer over years, then injects a malicious commit with enough cover to pass review. The CMake build script embedded a backdoor in liblzma that affected systemd-linked `sshd`. Lesson: **build scripts are attack surface with the same blast radius as source code**, but they get far less review.

### 3. Registry phase

**Image tag mutability.** `docker pull myapp:v1.2.3` today and in six weeks may yield different images if someone pushed a new layer under that tag. Only digest pinning (`sha256:...`) is immutable.

**Registry compromise or credential leak.** If write credentials for your registry are weak or leaked, an attacker can overwrite a tag silently. Third-party registries you pull base images from carry their own security posture risk.

**Image aging into vulnerability.** A clean image from three months ago now contains 47 critical CVEs from updated CVE databases. The image wasn't tampered with — it just aged into vulnerability while no one was looking.

### 4. Deploy and cluster phase

**Admission bypass.** No admission controller enforcing image signing or scanning means nothing prevents `kubectl run attack --image=attacker.io/rootkit` from running in a production namespace.

**Privileged workload as a supply-chain staging ground.** A container running as root with `CAP_SYS_ADMIN` can reach the Docker socket, build secrets, or registry credentials mounted in the same node — effectively compromising the next artifact produced.

---

## The 4 C's of cloud-native security

The [4 C's model](https://kubernetes.io/docs/concepts/security/cloud-native-security/) layers defenses: each C trusts the one below it, and a weakness at any level undermines everything above.

```
┌──────────────────────────────────────────────────────────────┐
│  Cloud  (IAM, VPC, KMS, audit logs, network perimeter)       │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Cluster  (RBAC, network policy, admission, etcd)    │    │
│  │  ┌────────────────────────────────────────────────┐  │    │
│  │  │  Container  (image signing, scanning, runtime)  │  │    │
│  │  │  ┌──────────────────────────────────────────┐  │  │    │
│  │  │  │  Code  (deps, lockfiles, SBOM, SAST)      │  │  │    │
│  │  │  └──────────────────────────────────────────┘  │  │    │
│  │  └────────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

Supply-chain attacks exploit **Code** and **Container** primarily, then leverage trust in those layers to bypass **Cluster** and **Cloud** controls. A signed image from a compromised build is still signed — the signature just doesn't prove what you think it proves. This is why you need **provenance** (who built it, from what source commit, on which build system) not just a signature.

---

## Real-world lessons: SolarWinds and xz-utils

### SolarWinds SUNBURST (2020)

The SUNBURST backdoor was injected into the SolarWinds Orion build process:

1. Attacker gained access to the build system (likely via a compromised developer credential).
2. The malicious code was injected **during compilation**, not into source files reviewed in PRs.
3. The resulting DLL was signed by SolarWinds' own certificate — a legitimate signature from a compromised build.
4. 18,000 customers installed the update because they trusted the signature.

The three controls that would have caught or prevented it: **reproducible builds** (anyone can verify the binary matches the source tree exactly), **hermetic build environments** (no persistent credentials, no outbound network during compilation), and **binary transparency logs** (a public append-only record of what was signed and when — a post-compromise forensic artifact).

### xz-utils backdoor (2024)

Jia Tan spent approximately two years becoming a trusted maintainer of xz-utils. The attack:

1. Hidden in test files and Autotools build scripts, not in the C source code that reviewers focused on.
2. Only activated when the library was linked with a patched glibc symbol resolver at init time of systemd-linked processes.
3. Specifically targeted `sshd` on systemd-based Linux distributions.
4. Caught by accident — an engineer noticed `ssh` was ~500ms slower than expected and traced it to CPU anomalies during RSA key decryption.

What makes this canonical for supply-chain defenders: the attack was patient (years), the injection point was the build system not the source, and the trigger was environment-specific. **No amount of runtime security fixes an artifact that was malicious before it was deployed.**

The key lesson: evaluate the human supply chain too. A new maintainer with no prior open-source history who volunteers to take over maintenance of a widely-used library is a signal worth investigating before giving merge access.

---

## Defense-in-depth across the chain

No single control is sufficient. Defense-in-depth means every hop adds friction:

| Stage | Primary defenses | Detection signals |
|-------|-----------------|-------------------|
| Source / deps | Lockfile hash pinning, dependency review in PRs, SAST, signed commits | New transitive deps in PRs, version skew alerts, unknown maintainers on depended packages |
| Build | Hermetic CI (no outbound network during build), ephemeral runners, build provenance (SLSA), artifact signing | CI config diff on PRs, unexpected new build dependencies, binary diff on releases |
| Registry | Immutable tags by digest, image signing (cosign/sigstore), retention and deletion policies | Tag mutation alerts, unsigned image admission rejections, unexpected new image tags |
| Deploy | Admission controllers enforcing signing and scanning policy, RBAC, pod security standards | Admission audit logs, scan failures at gate, privileged pod creation events |
| Runtime | Seccomp profiles, AppArmor, non-root containers, read-only root filesystem, eBPF-based anomaly detection | Unexpected syscalls, new outbound network connections, filesystem writes in unexpected paths |

The goal is not to stop every attack absolutely — it's to make lateral movement expensive and auditable, so a compromised dep at layer 1 doesn't silently become a root shell in production six months later.

---

## Debugging recon: finding your chain's weak link

Before hardening your supply chain you need to see it. This is the reconnaissance phase a defender (or an attacker) would run against your cluster and codebase.

### Enumerate what's running and where it came from

```bash
# All distinct images running in the cluster
kubectl get pods -A \
  -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' \
  | sort -u

# Images NOT pinned to a digest (mutable — unknown content on next pull)
kubectl get pods -A \
  -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' \
  | grep -v '@sha256:' | sort -u
```

Any image without `@sha256:` is mutable — you don't know what will be pulled on the next pod restart or OOM kill.

### Check admission enforcement

```bash
# Is anything enforcing image policy at admission time?
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
```

No output, or only `kube-system` entries? Nothing is blocking unsigned or unscanned images from running.

### Audit CI permissions

```bash
# In a typical GitHub repo — what does CI have write access to?
grep -r 'permissions:' .github/workflows/ | head -20
grep -r 'write-all\|write-packages\|write-contents' .github/workflows/ | head -20
```

A job with `permissions: write-all` that triggers on `pull_request` from forks is a supply-chain risk — a fork PR that triggers CI gets write access to your registry or artifacts.

### Check for dependency advisory hits

```bash
# Python
pip install pip-audit
pip-audit

# Node.js
npm audit --audit-level=moderate

# Go
go install golang.org/x/vuln/cmd/govulncheck@latest
govulncheck ./...
```

---

## Debugging the threat model

### Symptom table

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| A new package appeared in the lockfile that no developer added deliberately | Dependency confusion — public registry served a package before the private one | Add scope-to-registry mapping in `.npmrc`/`pip.conf`; check the package's publisher |
| CI builds something different from what `docker build` produced locally | Non-hermetic build: CI has network access and pulled a dependency version that differs from local cache | Pin every tool version in CI explicitly; use `--network=none` for the compile step |
| An image tag that was working yesterday now fails health checks | Tag mutation — someone pushed new layers under the same tag | Switch to digest pinning; add tag immutability policy on the registry |
| `kubectl apply` runs fine but the image is from an unknown source | No admission webhook exists; anything can be deployed | Install Kyverno or Gatekeeper with a `require-image-registry` policy |
| A dependency in `go.sum` / `package-lock.json` doesn't match what's on the registry | Hash mismatch — either the lockfile was manually edited, or the registry served tampered content | Investigate the package; regenerate the lockfile from a clean environment; consider flagging for security review |

> **War story.** At a team I audited, the SBOM pipeline was green for every image. The team felt covered. On routine recon I found 14 images running in the `production` namespace whose tags were not in any registry I could access — they were pulled from a developer's personal Docker Hub account that was set to public. The images were legitimate (developer was iterating quickly and hadn't cleaned up), but they bypassed the entire scanning and signing pipeline because nothing at admission time checked where the image came from, only that it ran. An attacker who had compromised that Docker Hub account could have pushed a malicious layer under the same tag and had it running in production within minutes of a pod restart. The fix was two Kyverno policies: one allowing only images from `registry.corp.example.com`, and one requiring all images to be pinned to a digest. Both policies were added to `enforce` mode — `warn` mode doesn't protect you.

---

## Checkpoint

You're ready for the next module when you can, without looking anything up:

1. Name the four chokepoints in a software supply chain and give one real attack class for each.
2. Explain what "dependency confusion" means and why a private package registry doesn't automatically protect you.
3. Describe the SUNBURST attack at the supply-chain level — where was the code injected, and why did the signature not protect the customer?
4. Summarize the xz-utils attack in two sentences: what was injected, where was it hidden, and what caught it.
5. Draw the 4 C's model and mark which C supply-chain attacks primarily target.
6. From your own cluster, run the two commands that reveal unpinned (tag-only) images and explain why digest pinning is safer.
7. Explain why signing a binary does not protect against a build-time compromise — what does and doesn't a signature prove?
8. Given a CI workflow file with `permissions: write-all` on a `pull_request` trigger, explain the attack path and the minimal permission fix.

➡ Next up: **Dependency Security** — lockfiles, hash pinning, transitive risk, typosquatting in depth, and Dependabot/Renovate in practice.
