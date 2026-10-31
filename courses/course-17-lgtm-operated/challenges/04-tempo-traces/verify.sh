#!/usr/bin/env bash
# Verifier for "Tempo — Ship the Trace Receiver".
# Checks: Helm release 'tempo' present, a Service exposes OTLP port 4317/4318,
# at least one Tempo pod is Ready.  Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-lgtm
FLAG='KUBE{tempo_otlp_receiver_deployed}'

fail() { echo "✗ $1"; exit 1; }

# ── 1. Namespace ─────────────────────────────────────────────────────────────
kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' is missing — run setup.sh first"

# ── 2. Helm release named 'tempo' ────────────────────────────────────────────
helm -n "$NS" list -q 2>/dev/null | grep -q '^tempo$' \
  || fail "Helm release 'tempo' not found in $NS — the release MUST be named 'tempo' (helm install tempo grafana/tempo ...)"

# ── 3. A Service exposing an OTLP port (4317 or 4318) ────────────────────────
ALL_PORTS=$(kubectl -n "$NS" get svc \
  -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.port}{"\n"}{end}{end}' 2>/dev/null)
OTLP_SVC_NAME=$(kubectl -n "$NS" get svc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.ports[*]}{.port}{" "}{end}{"\n"}{end}' \
  2>/dev/null | awk '$0 ~ /\t.*4317/ || $0 ~ /\t.*4318/ {print $1; exit}')

[ -n "$OTLP_SVC_NAME" ] \
  || fail "no Service in $NS exposes OTLP port 4317 or 4318 — enable the OTLP receiver: --set tempo.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317"

# ── 4. At least one Tempo pod Ready ──────────────────────────────────────────
READY=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=tempo" \
  -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.ready}{"\n"}{end}{end}' \
  2>/dev/null | grep -c '^true$' || true)

[ "${READY:-0}" -ge 1 ] \
  || fail "no Tempo pod (label app.kubernetes.io/instance=tempo) is Ready in $NS — check: kubectl -n $NS get pods"

# ── All checks passed ─────────────────────────────────────────────────────────
echo "✓ Helm release 'tempo'        : present in $NS"
echo "✓ OTLP Service                : $OTLP_SVC_NAME (port 4317/4318 exposed)"
echo "✓ Tempo pods Ready            : $READY"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
