# Fat Image Diet

A new team member just pushed a Docker image to the registry. It's supposed to serve a simple static website — maybe 50 MB at most. It came in at **1.2 GB**.

You open the Dockerfile and your eyes go wide. The layers are in completely the wrong order. `COPY . .` runs *before* `RUN npm ci`. Every time the source code changes, all 47 packages reinstall from scratch. The build cache is useless.

But there's something else hiding in this image. The developer left a trail — something tucked into the image's metadata labels. Find it.

## Mission

1. Run the setup script to build the fat image on your machine.
2. Use `docker history` and `docker inspect` to understand what's wrong with the layer order.
3. Find the flag hidden in the image labels.

This is a **discovery** challenge — the flag is embedded in the image itself. No verifier script to run; just submit the flag when you find it.

## Why This Matters

Docker builds images as a **stack of read-only layers**. Each `RUN`, `COPY`, and `ADD` instruction creates a new layer. The build cache works top-down: the moment an instruction's inputs change, every layer below it rebuilds.

This means layer order is not cosmetic — it's a performance contract. Put volatile stuff (source code) *above* stable stuff (dependency installs), and you've condemned your team to 8-minute CI builds for every typo fix.

```
# Wrong order — cache dies on every code edit
COPY . .             # ← source code changes every commit
RUN npm ci           # ← reinstalls 500 MB of packages every time

# Right order — deps cached until package files change
COPY package.json package-lock.json ./
RUN npm ci           # ← only re-runs when package.json changes
COPY . .             # ← source goes last
```

## Setup

```bash
bash courses/course-37-docker-internals/challenges/01-fat-image-diet/setup.sh
```

After setup, the image `dojo/fat-image:1.0` will be available on your host Docker daemon.
