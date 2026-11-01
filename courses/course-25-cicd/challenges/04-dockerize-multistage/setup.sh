#!/usr/bin/env bash
# Plants the "Dockerize Multi-Stage" starter into the work directory.
# Idempotent — re-running overwrites the source files but leaves any
# Dockerfile / build.sh you have already written untouched.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-dockerize-multistage"
mkdir -p "$WORK"

# Warn (don't fail) if Docker is not running
docker info >/dev/null 2>&1 || echo "WARNING: Docker does not appear to be running. Start Docker Desktop before working on this challenge."

# ── go.mod ───────────────────────────────────────────────────────────────────
cat > "$WORK/go.mod" << 'GOMOD'
module dojo-app

go 1.22
GOMOD

# ── main.go ──────────────────────────────────────────────────────────────────
cat > "$WORK/main.go" << 'GOEOF'
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	port := "8080"
	if p := os.Getenv("PORT"); p != "" {
		port = p
	}
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "dojo-multistage running")
	})
	fmt.Printf("listening on :%s\n", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
GOEOF

# ── Dockerfile stub (only written if not already present) ────────────────────
if [ ! -f "$WORK/Dockerfile" ]; then
  cat > "$WORK/Dockerfile" << 'DFEOF'
# TODO: write a multi-stage Dockerfile.
#
# Stage 1 (builder):  use golang:1.22-alpine, compile with CGO_ENABLED=0.
# Stage 2 (runtime):  use alpine:3.19, create a non-root user, copy only
#                     the compiled binary from the builder stage.
# App listens on port 8080.
DFEOF
fi

# ── build.sh stub (only written if not already present) ──────────────────────
if [ ! -f "$WORK/build.sh" ]; then
  cat > "$WORK/build.sh" << 'BSEOF'
#!/usr/bin/env bash
set -euo pipefail
IMAGE="${1:-dojo-multistage:latest}"
# TODO: run docker build here
echo "Build $IMAGE"
BSEOF
  chmod +x "$WORK/build.sh"
fi

echo
echo "Work directory : $WORK"
echo
echo "Files planted:"
echo "  main.go      — Go HTTP server (GET /healthz → ok)"
echo "  go.mod       — module dojo-app, go 1.22"
echo "  Dockerfile   — write a multi-stage build here"
echo "  build.sh     — write the build invocation here"
echo
echo "Task           : author a multi-stage Dockerfile (≥2 FROM instructions)"
echo "                 with a non-root runtime user, then write build.sh."
echo
echo "Prereqs        : Docker installed and running (docker version)"
echo
echo "Verify + flag  : bash courses/course-25-cicd/challenges/04-dockerize-multistage/verify.sh"
