# Solution — LogQL Needle

The flag is `KUBE{logql_needle_found}`.

## How it's planted

`setup.sh` runs a `busybox:1.36` pod that outputs ~500 fake HTTP access log lines, then one structured line:

```
audit-event level=INFO ts=2026-... source=access-log FLAG=KUBE{logql_needle_found} reason=config_reload instance=log-flood-xxx
```

Then 500 more noise lines, then repeats every 60 seconds.

## Extraction path 1 — kubectl logs (always works)

```bash
kubectl -n dojo-obs logs -l app=log-flood --tail=-1 | grep 'FLAG='
```

Output:

```
audit-event level=INFO ts=2026-10-31T... FLAG=KUBE{logql_needle_found} reason=config_reload instance=log-flood
```

The flag value is `KUBE{logql_needle_found}`.

`--tail=-1` is the flag that means "from the beginning of the buffer" — without it, `kubectl logs` defaults to the last 10 lines, which almost certainly misses the needle.

## Extraction path 2 — LogQL in Grafana

With Loki installed and Grafana configured:

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
# http://localhost:3000 → Explore → Loki datasource
```

Query:

```logql
{namespace="dojo-obs", pod=~"log-flood.*"} |= "FLAG="
```

The `|=` operator is a line filter — "keep only lines containing this substring." It executes at the Loki store before data is sent to Grafana. For a 100 GB/day pipeline, that's the difference between pulling gigabytes to the client vs. a few kilobytes of matching lines.

More precise query using a label parser:

```logql
{namespace="dojo-obs", pod=~"log-flood.*"} |= "FLAG=" | logfmt | FLAG != ""
```

`| logfmt` parses the log line as logfmt key=value pairs, promoting `FLAG` to a label. Then `FLAG != ""` filters to lines where that label was extracted.

## Performance note — why LogQL beats kubectl logs at scale

| Approach | Bytes transferred from store | Scales to 1 TB/day? |
|----------|------------------------------|---------------------|
| `kubectl logs --tail=-1 \| grep` | **All** pod log bytes, to your machine | No |
| LogQL `\|= "FLAG="` | Only matching log chunks | Yes |
| LogQL `\| logfmt \| FLAG != ""` | Matching chunks + Loki index lookup | Yes + faster |

The index lookup (when a label is extracted and indexed by Loki) avoids even scanning chunks where no log line could match — pure seek performance, like a B-tree on text.
