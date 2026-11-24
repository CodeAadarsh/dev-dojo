# kube-bench CIS Hardening — Solution

## Objective

Delete the `overprivileged-binding` ClusterRoleBinding (CIS 5.1.1 finding), which grants `cluster-admin` to the default ServiceAccount in `dojo-sec-bench`. The watcher pod will detect the deletion and write the flag.

---

## Steps

### Step 1: Read the kube-bench report

```bash
kubectl get configmap kube-bench-report -n dojo-sec-bench -o jsonpath='{.data.report\.txt}'
```

Key finding:
```
[FAIL] 5.1.1 Ensure that the cluster-admin role is only used where required
       REMEDIATION: Remove ClusterRoleBinding 'overprivileged-binding' which grants cluster-admin
       to ServiceAccount 'default' in namespace 'dojo-sec-bench'.
```

### Step 2: Inspect the offending ClusterRoleBinding

```bash
kubectl describe clusterrolebinding overprivileged-binding
```

Output:
```
Name:         overprivileged-binding
Subjects:
  Kind             Name     Namespace
  ----             ----     ---------
  ServiceAccount   default  dojo-sec-bench
Role:
  Kind:  ClusterRole
  Name:  cluster-admin
```

This gives the `default` ServiceAccount in `dojo-sec-bench` full admin access to the entire cluster. Any pod running in that namespace (without an explicit SA) has cluster-admin.

### Step 3: Delete the binding

```bash
kubectl delete clusterrolebinding overprivileged-binding
```

### Step 4: Wait for the watcher pod to detect the deletion

```bash
kubectl logs -f bench-watcher -n dojo-sec-bench
# Should show: "CRB removed! Writing flag..."
```

### Step 5: Retrieve the flag

```bash
kubectl get configmap cis-hardening-flag -n dojo-sec-bench -o jsonpath='{.data.flag}'
```

**Flag:** `KUBE{cis_benchmark_cluster_admin_removed}`

---

## Remediating All 5 Findings

### 1.2.1 — Disable anonymous auth

```yaml
# kube-apiserver manifest: /etc/kubernetes/manifests/kube-apiserver.yaml
# Add flag:
- --anonymous-auth=false
```

### 1.2.6 — AlwaysPullImages admission controller

```yaml
# Add to --enable-admission-plugins:
- --enable-admission-plugins=NodeRestriction,AlwaysPullImages
```

### 4.2.2 — Kubelet authorization mode

```yaml
# /var/lib/kubelet/config.yaml
authorization:
  mode: Webhook   # not AlwaysAllow
```

### 5.1.1 — Remove cluster-admin bindings (done above)

### 5.2.1 — Enforce Pod Security Standards

```bash
# Label namespaces with PSS enforcement
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

---

## Running Real kube-bench

```bash
# As a Kubernetes Job (preferred)
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml

# View results
kubectl logs job/kube-bench

# Target specific section
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-master
spec:
  template:
    spec:
      hostPID: true
      containers:
      - name: kube-bench
        image: docker.io/aquasec/kube-bench:latest
        command: ["kube-bench", "run", "--targets=master"]
        volumeMounts:
        - name: var-lib-etcd
          mountPath: /var/lib/etcd
          readOnly: true
        - name: etc-kubernetes
          mountPath: /etc/kubernetes
          readOnly: true
      volumes:
      - name: var-lib-etcd
        hostPath:
          path: /var/lib/etcd
      - name: etc-kubernetes
        hostPath:
          path: /etc/kubernetes
      restartPolicy: Never
EOF
```
