# Imperative Speed Run

**This is a timed, CKAD-style task. Start a stopwatch. Target: 5 minutes.**

You're in the exam terminal. The task card reads:

> *In namespace `dojo-exam`, create a Deployment named `speedy` running `nginx:1.27-alpine` with **3 replicas**, and expose it with a **ClusterIP** Service on **port 80**. Weight: 4%.*

That's the whole task. No probes, no resources, no YAML files handed to you. The only thing being tested is whether you can produce correct cluster state *fast* — which, on CKAD, is most of the exam.

The setup script has created an empty `dojo-exam` namespace for you. Nothing else is planted — you build it all.

## Mission / target state

The verifier accepts your work only when **all** of these are true:

1. A **Deployment** named `speedy` exists in namespace `dojo-exam`.
2. Its `spec.replicas` is exactly **3**.
3. Its pod container image contains **`nginx`** (use `nginx:1.27-alpine`).
4. A **Service** exists in `dojo-exam` that **selects** the `speedy` pods (its selector matches the Deployment's pod labels — not just any Service).
5. That Service exposes **port 80**.

## Rules of engagement

- **Imperative only.** The point of the drill is `kubectl create` / `kubectl expose`, not hand-written YAML. (The verifier only inspects final state, so it *can't* tell — but you're cheating your own exam prep if you author YAML here.)
- Work in namespace `dojo-exam` (the setup script creates it). Save a `-n dojo-exam` on every command by setting it as your default context namespace first.
- Beat the clock. If you're past 5 minutes, you'd have flagged this task and moved on in the real exam — note where you lost time.

## Why it matters

On CKAD, a task like this should cost you **90 seconds, not 5 minutes**. The gap between those two numbers — multiplied across ~17 tasks — is the difference between finishing with time to spare and running out before the troubleshooting tasks. The two commands that win it (`kubectl create deploy` and `kubectl expose deploy`) are the exact muscle memory the exam rewards, and `expose` wiring the selector for you is precisely why it beats `kubectl create svc` here.

When the cluster is in the target state, run the verifier. It inspects your live objects and prints the flag only if every check passes.
