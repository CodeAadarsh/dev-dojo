#!/usr/bin/env bash
# Plants the build-integrity Next.js app.
# The app has one deliberate build-breaking mistake: ServerData.tsx imports
# `server-only` but is used inside a Client Component (dashboard/page.tsx has
# 'use client' + imports ServerData). The fix is to remove 'use client' from
# dashboard/page.tsx (it doesn't use any client APIs) or to stop importing
# ServerData from a client component.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-build-integrity"
mkdir -p "$WORK/app/dashboard" "$WORK/app/api/status" "$WORK/components"

# ── package.json ──────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "build-integrity",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "build": "next build",
    "dev": "next dev"
  },
  "dependencies": {
    "next": "14.2.29",
    "react": "18.3.1",
    "react-dom": "18.3.1",
    "server-only": "0.0.1"
  },
  "devDependencies": {
    "@types/node": "20.14.2",
    "@types/react": "18.3.3",
    "@types/react-dom": "18.3.0",
    "typescript": "5.5.2"
  }
}
EOF

# ── next.config.js ────────────────────────────────────────────────────────────
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

# ── app/layout.tsx ────────────────────────────────────────────────────────────
cat > "$WORK/app/layout.tsx" << 'EOF'
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Build Integrity App",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
EOF

# ── app/page.tsx ──────────────────────────────────────────────────────────────
cat > "$WORK/app/page.tsx" << 'EOF'
export default function Home() {
  return (
    <main>
      <h1>Home</h1>
      <a href="/dashboard">Go to dashboard</a>
    </main>
  );
}
EOF

# ── components/ServerData.tsx — imports server-only ──────────────────────────
# This component is intentionally server-only. Importing it from a Client
# Component is the bug.
cat > "$WORK/components/ServerData.tsx" << 'EOF'
import "server-only";

export function ServerData() {
  return <p>Server-rendered data: {new Date().toISOString()}</p>;
}
EOF

# ── app/dashboard/page.tsx — THE BUG: 'use client' + imports ServerData ──────
cat > "$WORK/app/dashboard/page.tsx" << 'EOF'
"use client";

import { ServerData } from "@/components/ServerData";

export default function DashboardPage() {
  return (
    <section>
      <h1>Dashboard</h1>
      <ServerData />
    </section>
  );
}
EOF

# ── app/api/status/route.ts ───────────────────────────────────────────────────
cat > "$WORK/app/api/status/route.ts" << 'EOF'
import { NextResponse } from "next/server";

export async function GET() {
  return NextResponse.json({ status: "ok", ts: Date.now() });
}
EOF

echo
echo "Work directory : $WORK"
echo
echo "Bug            : one file has a client/server boundary violation."
echo "                 Running 'npx next build' will show you the error."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Try the build  : cd $WORK && npx next build 2>&1 | head -60"
echo "Verify + flag  : bash courses/course-32-nextjs-production/challenges/05-build-integrity/verify.sh"
