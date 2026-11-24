# IMDS Credential Theft

Your red team engagement just started. The target is a Kubernetes cluster running on a cloud provider. You've gained a foothold — a Remote Code Execution vulnerability in a web service gave you a shell inside pod `attacker-foothold` in namespace `dojo-sec-imds`.

Standard operating procedure for cloud-hosted containers: **check the Instance Metadata Service (IMDS)**. On AWS, GCP, and Azure, every EC2/GCE/VM instance exposes a special non-routable IP — `169.254.169.254` — that returns IAM credentials, instance identity, and configuration. If a pod can reach that IP, it can steal the node's cloud credentials.

In this lab, we simulate the IMDS with a fake server (`fake-imds-svc`) that mimics the AWS IMDS v1 API. It has the same endpoints, the same response format, and the same vulnerability.

## Mission

Retrieve the IAM credentials from the simulated IMDS service from inside the attacker foothold pod. The flag is embedded in the credential response.

## Attack path

1. `kubectl exec` into `attacker-foothold` in namespace `dojo-sec-imds`
2. Probe the IMDS endpoint at `http://fake-imds-svc`
3. Navigate the IMDS metadata paths to reach the IAM credential endpoint
4. The flag is in the credential response — read it and submit it

## Why this matters

On a real AWS cluster without IMDS v2 enforcement or a blocking NetworkPolicy, any compromised pod can run:

```bash
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
# lists the attached IAM role

curl http://169.254.169.254/latest/meta-data/iam/security-credentials/node-role
# returns AccessKeyId, SecretAccessKey, Token — full AWS credentials
```

Those credentials carry whatever permissions the EC2 node's IAM role has — often `ec2:Describe*`, S3 read access, and sometimes cluster admin. The fix: enforce **IMDSv2** (requires a PUT to get a session token before GET requests work) and add a **NetworkPolicy egress rule blocking 169.254.169.254/32**.

## Rules of engagement

- Namespace: `dojo-sec-imds`
- Your foothold: pod `attacker-foothold`
- IMDS simulation: `http://fake-imds-svc` (Service in the same namespace)
- Flag format: `KUBE{...}` — submit it on the platform
