#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-multistage"

echo "==> Setting up challenge 04-multi-stage-go"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap go-app-source \
  --from-literal=main.go='package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "hello from dojo")
	})
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	http.ListenAndServe(":"+port, nil)
}' \
  --from-literal=go.mod='module dojo/app

go 1.23' \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap fat-dockerfile \
  --from-literal=Dockerfile='FROM golang:1.23-alpine
WORKDIR /src
COPY . .
RUN go build -o /app ./...
EXPOSE 8080
ENTRYPOINT ["/app"]

# This ships the entire Go toolchain in production — the image is ~400MB
# Your task: rewrite this as a multi-stage build so the final image is under 20MB' \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✓ Namespace: $NAMESPACE"
echo "✓ ConfigMap: go-app-source (main.go + go.mod)"
echo "✓ ConfigMap: fat-dockerfile (the broken single-stage Dockerfile)"
echo ""
echo "Get the source:"
echo "  kubectl get configmap go-app-source -n $NAMESPACE -o jsonpath='{.data.main\\.go}'"
echo "  kubectl get configmap go-app-source -n $NAMESPACE -o jsonpath='{.data.go\\.mod}'"
echo ""
echo "Build your multi-stage image, load it into kind, and deploy as 'go-app-slim'."
