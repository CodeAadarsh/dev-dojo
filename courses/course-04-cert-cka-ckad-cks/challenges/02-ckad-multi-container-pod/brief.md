# Sidecar Speed Run

A CKAD favourite, and a real pattern: two containers in one Pod that cooperate through a **shared `emptyDir` volume** — a classic sidecar. One container produces, the other consumes.

Treat this like the exam: generate the skeleton, edit the delta, verify, move on. Target: **under 5 minutes.**

## Mission

In namespace `dojo-ckad` (created by setup), create a **single Pod** with **two containers** that share an `emptyDir`:

- a **writer** container (`busybox:1.36`) that appends to a file on the shared volume in a loop, e.g. `sh -c 'while true; do date >> /data/out.log; sleep 2; done'`
- a **reader** container (`busybox:1.36`) that tails the same file, e.g. `sh -c 'sleep 5; tail -f /data/out.log'`
- both mounting the same `emptyDir` volume (the writer at `/data`, the reader at `/data`).

The Pod must be **Running**.

## Why it matters

`emptyDir` lives and dies with the Pod and is shared by all its containers — the simplest inter-container channel. This is the mechanics behind log-shipping sidecars, config-reloaders, and the service-mesh proxy pattern. The exam tests whether you can wire a shared volume quickly without fumbling the YAML.

Run the verifier when your Pod is Running.
