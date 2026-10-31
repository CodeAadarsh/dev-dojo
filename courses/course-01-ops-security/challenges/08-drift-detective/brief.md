# Drift Detective

2:14 AM. Someone on call ran `kubectl scale deploy/guestbook-ui --replicas=4` to ride out a traffic spike and never reverted it. Git still says **1 replica**. It's now three days later and the live cluster *still* says 4 — Argo CD shows the app `OutOfSync` but hasn't touched it. The team assumed GitOps would "just fix it." It didn't.

This is the exact failure mode that bites teams who turn on Argo CD's `automated` sync and assume that covers everything. It doesn't: **auto-sync reacts to Git changes; `selfHeal` reacts to cluster drift.** They are two separate switches. This app has the first and not the second.

Your job: be the drift detective. Confirm the drift, understand why the controller is sitting on its hands, then make Argo CD enforce Git.

## Prerequisite

Argo CD must be installed in the cluster. If you haven't already:

```bash
bash labs/bootstrap/install-argocd.sh
```

## The setup

Running `setup.sh`:

- ensures namespace `dojo-drift` exists,
- creates an Argo CD `Application` named `drift-detective` targeting the same example repo (`guestbook` → `dojo-drift`) **with `syncPolicy.automated.selfHeal: false`**,
- waits for it to sync and go Healthy,
- then **manually scales `guestbook-ui` to introduce drift** — pushing the live replica count away from what Git declares.

After setup, the Application will report `OutOfSync` and stay that way, because self-heal is off.

## Mission

Make Argo CD reconcile the drift away by **enabling automated self-heal** on the `drift-detective` Application. Once self-heal is on, the controller detects that live state ≠ Git and reverts the manual change, driving the app back to `Synced`.

## Target state — what the verifier checks

The verifier accepts your work only when the `drift-detective` Application (in the `argocd` namespace) satisfies **both**:

1. **`spec.syncPolicy.automated.selfHeal == true`** — the enforcement switch is on.
2. **`status.sync.status == Synced`** — the drift has actually been reverted; live state matches Git again.

> **`OutOfSync` → `Synced`, and why `selfHeal` is the hinge.** `automated` (with only `prune`) means Argo CD auto-applies whenever *Git* changes — but a manual `kubectl` edit isn't a Git change, so the controller notices the drift (marks it `OutOfSync`) and deliberately leaves it alone, trusting the human. Add `selfHeal: true` and the contract flips: Argo CD now treats *any* divergence from Git — including live edits — as something to correct, continuously re-applying the Git state until the two match. That's the difference between GitOps that *reports* drift and GitOps that *prevents* it.

When both conditions hold, the verifier prints your flag.
