# Solution: Network Detective

## Step 1 — Diagnose: empty endpoints

```bash
kubectl get endpoints backend-svc -n dojo-docker-network
# NAME          ENDPOINTS   AGE
# backend-svc   <none>      3m    ← the smoking gun
```

Empty `ENDPOINTS` means the Service selector matches zero pods. kube-proxy has no IPs to route to, so all traffic hits a dead end.

## Step 2 — Find the mismatch

```bash
# What does the Service selector say?
kubectl get service backend-svc -n dojo-docker-network \
  -o jsonpath='{.spec.selector}'
# {"app":"backend-wrong"}    ← looking for "backend-wrong"

# What do the pods actually have?
kubectl get pods -n dojo-docker-network --show-labels
# NAME                       LABELS
# backend-xxx   app=backend  ← pods are labeled "backend"
```

The Service is looking for `app=backend-wrong`. The pods have `app=backend`. One typo in the selector = zero connectivity.

## Step 3 — Fix the selector

```bash
kubectl patch service backend-svc -n dojo-docker-network \
  -p '{"spec":{"selector":{"app":"backend"}}}'
```

## Step 4 — Confirm endpoints populated

```bash
kubectl get endpoints backend-svc -n dojo-docker-network
# NAME          ENDPOINTS                     AGE
# backend-svc   10.244.0.5:80,10.244.0.6:80   3m   ← now populated
```

## Step 5 — Test connectivity from frontend

```bash
FRONT_POD=$(kubectl get pod -n dojo-docker-network -l app=frontend \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n dojo-docker-network "$FRONT_POD" -- \
  curl -s http://backend-svc/
# Returns nginx welcome page from the backend
```

## Step 6 — Verify and get the flag

```bash
bash courses/course-37-docker-internals/challenges/08-network-detective/verify.sh
```

**Flag:** `KUBE{iptables_rules_docker_network}`

## The Full Network Path

When `frontend` calls `http://backend-svc/`, here's what happens:

```
1. DNS: "backend-svc" → CoreDNS → ClusterIP (e.g. 10.96.42.10)

2. Frontend pod sends packet to 10.96.42.10:80

3. iptables PREROUTING chain (KUBE-SERVICES):
   -A KUBE-SERVICES -d 10.96.42.10/32 -p tcp --dport 80 -j KUBE-SVC-xxx

4. KUBE-SVC-xxx chains: random-select an endpoint
   -A KUBE-SVC-xxx -m statistic --mode random --probability 0.5 -j KUBE-SEP-aaa
   -A KUBE-SVC-xxx -j KUBE-SEP-bbb

5. KUBE-SEP-aaa does DNAT:
   -A KUBE-SEP-aaa -p tcp -j DNAT --to-destination 10.244.0.5:80

6. Packet arrives at backend pod 10.244.0.5:80
```

The Endpoints object is what kube-proxy reads to generate steps 4 and 5. Empty Endpoints = no DNAT rules = packet goes nowhere.
