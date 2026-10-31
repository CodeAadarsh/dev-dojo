#!/usr/bin/env bash
# Plants the "LogQL Needle" scenario: a pod that logs a flood of fake HTTP
# access log lines, with one line containing FLAG=KUBE{...} buried in the noise.
set -euo pipefail

NS=dojo-obs
FLAG_VALUE='KUBE{logql_needle_found}'

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# The pod script:
#  - logs 500 lines of realistic fake HTTP access logs (noise)
#  - logs ONE line containing FLAG= buried at a pseudo-random offset
#  - continues logging 500 more noise lines, then repeats every 60s
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: log-flood
  namespace: dojo-obs
  labels:
    app: log-flood
spec:
  restartPolicy: Always
  containers:
    - name: flooder
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          METHODS="GET POST PUT DELETE"
          PATHS="/api/v1/users /api/v1/orders /health /metrics /api/v2/products /api/v1/invoices /auth/token"
          STATUSES="200 200 200 200 301 400 404 500"
          log_noise() {
            i=0
            while [ "\$i" -lt "\$1" ]; do
              METHOD=\$(echo \$METHODS | tr ' ' '\\n' | awk "NR==(\$RANDOM%4+1)")
              PATH=\$(echo \$PATHS | tr ' ' '\\n' | awk "NR==(\$RANDOM%7+1)")
              STATUS=\$(echo \$STATUSES | tr ' ' '\\n' | awk "NR==(\$RANDOM%8+1)")
              MS=\$(( RANDOM % 450 + 5 ))
              echo "10.\$(( RANDOM%254+1 )).\$(( RANDOM%254+1 )).\$(( RANDOM%254+1 )) - - [\$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"\$METHOD \$PATH HTTP/1.1\" \$STATUS \$(( RANDOM%8192+64 )) \$MS"
              i=\$(( i + 1 ))
            done
          }
          while true; do
            log_noise 500
            echo "audit-event level=INFO ts=\$(date -u +%Y-%m-%dT%H:%M:%SZ) source=access-log FLAG=${FLAG_VALUE} reason=config_reload instance=\$(hostname)"
            log_noise 500
            sleep 60
          done
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Pod 'log-flood' is streaming ~1000 noise lines per cycle with ONE flag line hidden inside."
echo
echo "  Fallback (always works):"
echo "    kubectl -n $NS logs -l app=log-flood --tail=-1 | grep 'FLAG='"
echo
echo "  LogQL (if Loki is installed):"
echo "    kubectl -n monitoring port-forward svc/kps-grafana 3000:80"
echo "    # Grafana → Explore → Loki → {namespace=\"dojo-obs\", pod=~\"log-flood.*\"} |= \"FLAG=\""
