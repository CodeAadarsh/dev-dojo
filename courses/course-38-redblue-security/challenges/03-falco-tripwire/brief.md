# Falco Tripwire

Falco catches attackers by watching syscalls. But you need to know WHICH rules fire for WHICH actions — and you need to know how to write your own rules when the defaults aren't enough.

In this challenge, we've pre-simulated three Falco alert types in a ConfigMap. Your job is to study the alert patterns, then prove you understand Falco by writing a custom rule that would have caught the attacker even earlier.

## Mission

1. Read the simulated Falco alerts in ConfigMap `falco-simulation` in namespace `dojo-sec-falco`
2. Identify which 3 Falco rules fired
3. Write a custom Falco rule that would have detected the initial reconnaissance (before those 3 events)
4. Save your rule to `/tmp/custom-falco-rule.yaml` on your local machine
5. Run the verifier — it checks your rule has valid Falco structure

## What Happened (Simulated)

An attacker got into a container, ran a shell, tried to read sensitive files, and installed a package. Falco caught all three. But what about the FIRST thing the attacker did — checking what tools are available? That happened before Falco's rules fired.

You'll write a rule that catches `ls /usr/bin` or `which curl` — the quiet reconnaissance commands that the default ruleset misses.

## Why This Matters

Default Falco rules cover known techniques well but have gaps:
- They don't alert on `ls`, `find`, `cat /proc/net/tcp` — normal-looking commands
- An attacker who knows Falco's defaults can operate quietly in those gaps
- Security teams must tune Falco with custom rules for their specific threat model

## Rules of Engagement

- Namespace: `dojo-sec-falco`
- Simulated alerts: `kubectl get configmap falco-simulation -n dojo-sec-falco -o jsonpath='{.data.alerts}'`
- Write your custom rule to `/tmp/custom-falco-rule.yaml`
- Required fields in your rule: `rule`, `condition`, `output`, `priority`
- The rule must detect: a process running `ls` inside a container
- Run verify.sh after writing your rule

## Example Falco Rule Structure

```yaml
- rule: My Custom Rule
  desc: Detects something suspicious
  condition: >
    evt.type = execve
    and container
    and proc.name = "something"
  output: >
    Suspicious process (user=%user.name container=%container.name proc=%proc.name)
  priority: WARNING
```
