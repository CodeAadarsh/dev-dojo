# Ship From Your Own Registry

Every image you've deployed so far came from a public registry — Docker Hub's `nginx`, `busybox`. In production your images come from a **private registry** you control: an internal Harbor, ECR, GCR, Artifactory, or a bare `registry:2`. The deploy loop is always the same four moves, and getting them wrong is the single most common reason a new cluster can't start a pod:

```
build ──▶ tag ──▶ push ──▶ deploy
 (dev)   (name it   (send it   (manifest references
          for the    to the     the registry path,
          registry)  registry)  node pulls it)
```

This challenge makes you run that loop end-to-end against a registry running on your own machine, wired into the kind network so the cluster nodes can pull from it.

## Prerequisite — stand up the registry

Run the lab bootstrap helper **once** before you start:

```bash
bash labs/bootstrap/install-registry.sh
```

That script:

- starts a `registry:2` container published on `localhost:5001`,
- connects it to the `kind` Docker network so the nodes can reach it, and
- writes a `hosts.toml` into each node's containerd config so `localhost:5001` resolves to the registry *from inside the cluster*.

That last point is the subtle one. `localhost:5001` means the registry container **to your host** (that's where the port is published) **and** means the same registry **to each node** (because the bootstrap told containerd to map `localhost:5001` → `http://kind-registry:5000`). Same string, resolved correctly on both sides — which is exactly why your `docker push` target and your manifest's `image:` can be byte-for-byte identical.

## Mission

In namespace `dojo-registry`:

1. **Pull** a public image, e.g. `nginx:1.27-alpine`.
2. **Retag** it into your registry's namespace: `localhost:5001/<name>:v1`.
3. **Push** it to the local registry.
4. **Deploy** it — create a Deployment in `dojo-registry` whose container `image` is `localhost:5001/<name>:v1`, and get it to `Ready`.

> **Simpler alternative (also accepted conceptually):** `kind load docker-image <name>:v1 --name dojo` copies an image straight into every node's store with no registry at all. It's great for one-off local images — but it is **not** how a real cluster works, and the verifier specifically wants to see an image path that references `localhost:5001/`, so for this challenge push to the registry.

## Target state (what the verifier checks)

The verifier accepts your work only when **both** hold for some Deployment in `dojo-registry`:

1. **At least one container's `image` references `localhost:5001/`** — i.e. the pod pulls from your registry, not Docker Hub.
2. **That Deployment has `readyReplicas >= 1`** — the node actually pulled the image and the pod is running. (If the push or the containerd wiring is wrong, this stays `0` with `ErrImagePull`.)

## Why this matters

A registry is just a **repository for versioned artifacts** — the OCI-image equivalent of a Maven or npm repo. The reason "it works on my laptop but the cluster can't pull it" is nearly always one of three things: the image was never pushed (only built), the manifest references a tag that doesn't exist in the registry, or the node can't reach the registry at the name in the manifest. Running the loop by hand once, against a registry you can inspect, makes all three failure modes obvious the next time they page you at 3 a.m.

When the Deployment is `Ready`, run the verifier. It inspects live cluster state and prints the flag only if both checks pass.
