# Lateral Movement Chain — Three Hops to the Treasure

Real attackers don't stop at their initial foothold. They pivot. Each compromised component becomes a stepping stone to the next.

This challenge plants a 3-hop lateral movement chain. You start with limited access, discover and steal a ServiceAccount token, use it to pivot to another namespace, discover and steal another token, and finally reach the secret that holds the flag.

Each hop simulates a real lateral movement technique: discovering SA tokens, using stolen tokens with kubectl, pivoting across namespace boundaries.

## The Chain

```
START                     HOP 1                     HOP 2                    GOAL
─────                     ─────                     ─────                    ────
dojo-sec-lateral          dojo-sec-lateral          dojo-sec-lateral-hop2    dojo-sec-lateral-hop3
Your SA: minimal-sa       hop1-sa token             hop2-sa token            secret: final-treasure
Can: list pods            Can: get pods in hop2 ns  Can: get secrets in hop3  flag: KUBE{...}
```

## Mission

1. Start: you have a kubeconfig as `minimal-sa` in `dojo-sec-lateral` — can only list pods in that namespace
2. Find the pod that has a hop1-sa token mounted
3. That token can discover pods in `dojo-sec-lateral-hop2`
4. Find the pod in hop2 that has the hop2-sa token
5. That token can read secrets in `dojo-sec-lateral-hop3`
6. Read the `final-treasure` secret in `dojo-sec-lateral-hop3`
7. The flag is in the `flag` data field

## Rules of Engagement

- Starting namespace: `dojo-sec-lateral`
- Starting SA: `minimal-sa` (can list pods in `dojo-sec-lateral` only)
- Three namespaces: `dojo-sec-lateral`, `dojo-sec-lateral-hop2`, `dojo-sec-lateral-hop3`
- Use `kubectl --token=<stolen-token>` to operate as a different SA
- Tokens are mounted as secrets in pods — read them with `kubectl exec`
- Run verify.sh when you've retrieved the flag
