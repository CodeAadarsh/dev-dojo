#!/usr/bin/env bash
# Plants the "Logical Backup Job" scenario: a data-source ConfigMap in dojo-backup.
set -euo pipefail

NS=dojo-backup

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Plant a ConfigMap representing an application's exported data
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-data
  namespace: dojo-backup
data:
  records.json: |
    [
      {"id":1,"user":"alice","balance":4200},
      {"id":2,"user":"bob","balance":1337},
      {"id":3,"user":"carol","balance":9001}
    ]
  schema.sql: |
    CREATE TABLE users (id INTEGER PRIMARY KEY, user TEXT, balance INTEGER);
    INSERT INTO users VALUES (1,'alice',4200),(2,'bob',1337),(3,'carol',9001);
YAML

echo
echo "✓ Namespace '$NS' ready."
echo "  ConfigMap 'app-data' planted — this is your logical data source."
echo "  Your mission:"
echo "    1. Create a PVC named 'backup-store' in '$NS'."
echo "    2. Create a Job that mounts both the ConfigMap and the PVC,"
echo "       copies app-data into the PVC, and exits 0."
echo "  When the Job has succeeded, run verify.sh."
