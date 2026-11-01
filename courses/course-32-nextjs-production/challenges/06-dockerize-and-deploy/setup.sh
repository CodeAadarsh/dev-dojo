#!/usr/bin/env bash
# Plants the dockerize-and-deploy Next.js app + Dockerfile skeleton.
# Idempotent — re-running overwrites files but preserves node_modules.
set -euo pipefail

CTX="$(kubectl config current-context 2>/dev/null || true)"
if [ "$CTX" != "kind-dojo" ]; then
  echo "WARNING: current kubectl context is '${CTX:-<none>}', expected 'kind-dojo'."
  echo "         Run: kubectl config use-context kind-dojo"
  echo "         Continuing anyway — setup does not touch the cluster."
fi

WORK="$HOME/.kube-dojo-work/06-dockerize-and-deploy"
mkdir -p "$WORK/app/api/health" "$WORK/components"

# ── package.json ──────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "dojo-nextjs",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "build": "next build",
    "start": "node .next/standalone/server.js"
  },
  "dependencies": {
    "next": "14.2.29",
    "react": "18.3.1",
    "react-dom": "18.3.1"
  },
  "devDependencies": {
    "@types/node": "20.14.2",
    "@types/react": "18.3.3",
    "@types/react-dom": "18.3.0",
    "typescript": "5.5.2"
  }
}
EOF

# ── next.config.js ─────────────────────────────────────────────────────────────
cat > "$WORK/next.config.js" << 'EOF'
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
};

module.exports = nextConfig;
EOF

# ── tsconfig.json ─────────────────────────────────────────────────────────────
cat > "$WORK/tsconfig.json" << 'EOF'
{
  "compilerOptions": {
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": { "@/*": ["./*"] }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
EOF

# ── app/layout.tsx ─────────────────────────────────────────────────────────────
cat > "$WORK/app/layout.tsx" << 'EOF'
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
EOF

# ── app/page.tsx ───────────────────────────────────────────────────────────────
cat > "$WORK/app/page.tsx" << 'EOF'
import { Hero } from "@/components/Hero";

export default function Home() {
  return (
    <main>
      <Hero />
    </main>
  );
}
EOF

# ── components/Hero.tsx ────────────────────────────────────────────────────────
cat > "$WORK/components/Hero.tsx" << 'EOF'
export function Hero() {
  return (
    <section>
      <h1>dojo-nextjs</h1>
      <p>Deployed to Kubernetes via kind.</p>
    </section>
  );
}
EOF

# ── app/api/health/route.ts ────────────────────────────────────────────────────
cat > "$WORK/app/api/health/route.ts" << 'EOF'
import { NextResponse } from "next/server";

export async function GET() {
  return NextResponse.json({ status: "ok" }, { status: 200 });
}
EOF

# ── .dockerignore ──────────────────────────────────────────────────────────────
cat > "$WORK/.dockerignore" << 'EOF'
node_modules
.next
.git
*.md
EOF

# ── Dockerfile skeleton ────────────────────────────────────────────────────────
cat > "$WORK/Dockerfile" << 'EOF'
# Stage 1: builder
# TODO: choose a base image (node:20-alpine), set WORKDIR, copy package files,
#       run npm ci, copy the rest of the source, then run npm run build.

# Stage 2: runner
# TODO: use node:20-alpine, set NODE_ENV=production, set WORKDIR /app,
#       copy the standalone output from the builder stage:
#         .next/standalone  ->  /app
#         .next/static      ->  /app/.next/static
#         public            ->  /app/public  (if it exists)
#       EXPOSE 3000
#       ENV PORT=3000 HOSTNAME=0.0.0.0
#       CMD ["node", "server.js"]
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           :"
echo "  1. Complete $WORK/Dockerfile"
echo "  2. cd $WORK && npm install && docker build -t dojo-nextjs:v1 ."
echo "  3. kind load docker-image dojo-nextjs:v1 --name dojo"
echo "  4. Deploy to namespace dojo-nextjs (Deployment + Service)"
echo
echo "Verify + flag  : bash courses/course-32-nextjs-production/challenges/06-dockerize-and-deploy/verify.sh"
