# Registry Boss

This is the final challenge. No hints until you've tried.

Your organization is done with Docker Hub. Too many public image pulls, too many supply chain risks, too many surprise rate limits. The decision is made: **run your own private registry inside Kubernetes**, lock it down with authentication, push images to it, and deploy pods from it.

This is the OCI Distribution Specification in real life.

---

## What you are building

```
  Your Host                    kind cluster (dojo)
  ─────────                    ──────────────────────────────────────────
  docker push ──► port-forward ──► registry-svc ──► registry Pod
                                                      (registry:2.8.3
                                                       + htpasswd auth)

  Pod: registry-consumer ◄──── ImagePullSecret ◄─── you created this
       (pulls from your registry)
```

---

## Target state

The verifier checks **all six** of these:

1. Deployment `registry` is running in namespace `dojo-docker-registry`
2. At least one pod for the registry Deployment is in `Running` state
3. Service `registry-svc` exists in `dojo-docker-registry` on port 5000
4. Secret `registry-auth` exists in `dojo-docker-registry`
5. Pod `registry-consumer` exists in `dojo-docker-registry` and is `Running`
6. Deployment `registry` has annotation `dojo.docker/registry-verified: true`

**Auth credentials to use:** `username: dojo` / `password: docker-master`

---

## Setup

```bash
bash courses/course-37-docker-internals/challenges/15-registry-boss/setup.sh
```

## Verifier

```bash
bash courses/course-37-docker-internals/challenges/15-registry-boss/verify.sh
```

---

## Background: OCI Distribution Spec

Every `docker push` and `docker pull` is an HTTP conversation defined by the [OCI Distribution Specification](https://github.com/opencontainers/distribution-spec). The key endpoints:

```
GET  /v2/                              — API version check
GET  /v2/<name>/tags/list              — list tags
GET  /v2/<name>/manifests/<ref>        — pull manifest
PUT  /v2/<name>/manifests/<ref>        — push manifest
POST /v2/<name>/blobs/uploads/         — start blob upload
PUT  /v2/<name>/blobs/uploads/<uuid>   — complete blob upload
GET  /v2/<name>/blobs/<digest>         — pull blob (layer)
```

`registry:2.8.3` (Docker Distribution) is the reference implementation of this spec. You are deploying that.

Good luck.
