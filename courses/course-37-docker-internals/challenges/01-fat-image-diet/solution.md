# Solution: Fat Image Diet

## Step 1 — Read the layer history

```bash
docker history dojo/fat-image:1.0
```

You'll see something like:
```
IMAGE          CREATED        CREATED BY                                      SIZE
abc123         2 minutes ago  CMD ["node" "server.js"]                        0B
def456         2 minutes ago  LABEL docker.dojo.flag=KUBE{...}               0B
ghi789         2 minutes ago  RUN npm ci --omit=dev                          85MB   <-- big!
jkl012         2 minutes ago  COPY . .                                       4.5kB
mno345         3 weeks ago    /bin/sh -c #(nop) WORKDIR /app                 0B
pqr678         3 weeks ago    node:20-slim base layers                       ~200MB
```

The `RUN npm ci` layer (85 MB) sits *below* `COPY . .` — meaning any source code change busts the npm cache.

## Step 2 — Find the flag in the labels

```bash
docker inspect dojo/fat-image:1.0 --format '{{json .Config.Labels}}'
```

Output:
```json
{"docker.dojo.flag":"KUBE{layer_order_saves_rebuild_time}","docker.dojo.hint":"Layer order matters: ..."}
```

**Flag:** `KUBE{layer_order_saves_rebuild_time}`

## Why This Happened

Docker's build cache invalidates **top-down**. The first instruction whose inputs differ from the cache causes every layer below it to rebuild from scratch.

`COPY . .` copies ALL source files. Any code change — even a comment — changes this layer's checksum, busting the cache for `RUN npm ci` below it. The fix is to copy *only* the dependency manifest first:

```dockerfile
# CORRECT order
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./   # only changes when deps change
RUN npm ci --omit=dev                    # cached across code edits
COPY . .                                 # volatile source goes last
EXPOSE 3000
CMD ["node", "server.js"]
```

Now `npm ci` only re-runs when `package.json` or `package-lock.json` actually change. A pure source code edit rebuilds in seconds instead of minutes.

## The Layer Size Problem

The flag was in a `LABEL` instruction. Labels create zero-byte layers (they're metadata, not filesystem changes). But the lesson here is `docker inspect` — not just `docker history`. Production images often carry metadata that reveals build timestamps, git SHAs, CI pipeline info, and sometimes secrets that were accidentally labeled. Always audit before pushing to a public registry.
