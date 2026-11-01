#!/usr/bin/env bash
# Plants the "Dockerize and Deploy" starter project.
# Idempotent — re-running overwrites project files but preserves node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-dockerize-and-deploy"
mkdir -p "$WORK/src"

# ── package.json ─────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "dojo-node-api",
  "version": "1.0.0",
  "main": "dist/index.js",
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "express": "4.18.2"
  },
  "devDependencies": {
    "typescript": "5.4.5",
    "@types/node": "20.12.12",
    "@types/express": "4.17.21"
  }
}
EOF

# ── tsconfig.json ─────────────────────────────────────────────────────────────
cat > "$WORK/tsconfig.json" << 'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "CommonJS",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*"]
}
EOF

# ── src/index.ts ───────────────────────────────────────────────────────────────
cat > "$WORK/src/index.ts" << 'EOF'
import express, { Request, Response } from 'express';

const app = express();
const PORT = parseInt(process.env.PORT ?? '3000', 10);

app.use(express.json());

app.get('/health', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/items', (_req: Request, res: Response) => {
  res.status(200).json([
    { id: 1, name: 'Widget' },
    { id: 2, name: 'Gadget' },
  ]);
});

app.listen(PORT, () => {
  console.log(`dojo-node-api listening on port ${PORT}`);
});
EOF

# ── Dockerfile skeleton ────────────────────────────────────────────────────────
cat > "$WORK/Dockerfile" << 'EOF'
# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder
WORKDIR /app

# TODO: copy package.json and package-lock.json (if present) and install ALL deps
#       (including devDependencies — TypeScript is a devDep)

# TODO: copy the rest of the source and compile TypeScript
#       Hint: npm run build  (which calls tsc)


# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM node:20-alpine AS runtime
WORKDIR /app

# TODO: copy only the compiled output (dist/) and production node_modules from builder
#       Do NOT copy source files or dev dependencies.

# TODO: set a non-root user so the container does not run as root
#       node:20-alpine ships a built-in 'node' user (uid 1000) — use it.

ENV PORT=3000
EXPOSE 3000

CMD ["node", "dist/index.js"]
EOF

# ── print next steps ──────────────────────────────────────────────────────────
echo
echo "Work directory  : $WORK"
echo
echo "Task            :"
echo "  1. Complete the Dockerfile (fill in the TODOs)"
echo "  2. Build:  cd $WORK && docker build -t dojo-node-api:1.0.0 ."
echo "  3. Load:   kind load docker-image dojo-node-api:1.0.0 --name dojo"
echo "  4. Deploy: create a Deployment + Service in namespace dojo-node"
echo "             (image: dojo-node-api:1.0.0, readinessProbe on /health:3000)"
echo
echo "Prerequisites   :"
echo "  - Docker Desktop running"
echo "  - kind cluster 'dojo' running (kubectl config current-context -> kind-dojo)"
echo "  cd $WORK && npm install   (for local compile/test)"
echo
echo "Verify + flag   :"
echo "  bash courses/course-33-node-backend-scale/challenges/06-dockerize-and-deploy/verify.sh"
