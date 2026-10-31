# Solution — Sidecar Speed Run

```yaml
# pair.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pair
  namespace: dojo-ckad
spec:
  volumes:
    - name: shared
      emptyDir: {}
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "while true; do date >> /data/out.log; sleep 2; done"]
      volumeMounts:
        - name: shared
          mountPath: /data
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "sleep 5; tail -f /data/out.log"]
      volumeMounts:
        - name: shared
          mountPath: /data
```

```bash
kubectl apply -f pair.yaml
kubectl -n dojo-ckad get pod pair -o wide
# watch the sidecar read what the writer produced:
kubectl -n dojo-ckad logs pair -c reader
bash courses/course-04-cert-cka-ckad-cks/challenges/02-ckad-multi-container-pod/verify.sh
```

## Notes

- **One volume, two mounts.** The `emptyDir` named `shared` is declared once under `spec.volumes`; each container mounts it by that name. That's the entire sidecar channel.
- **Keep both containers alive.** If the reader's command exits (e.g. plain `cat`), the container restarts and the Pod flaps. `tail -f` (or a sleep loop) keeps it running. A container that exits 0 in a Pod still triggers restarts under the default `restartPolicy: Always`.
- **Exam speed:** generate with `kubectl run ... --dry-run=client -o yaml`, then add the second container and the volume by hand — faster than typing the whole manifest.
- Native **sidecar containers** (init containers with `restartPolicy: Always`, GA in 1.29+) are the modern way to guarantee sidecar start/stop ordering; the plain two-container Pod here is the CKAD-level pattern.
