#!/usr/bin/env bash
# Plants the scenario, starter answers.py, and checker.py for "Right-size + Spot".
# answers.py is not overwritten if it already exists (preserve learner progress).
# checker.py is always written fresh from setup (to allow updates).
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-right-size-and-spot"
mkdir -p "$WORK"

# ── scenario.md ──────────────────────────────────────────────────────────────
cat > "$WORK/scenario.md" << 'MDEOF'
# Right-size + Spot: Scenario & Formula Guide

## Workload

| Parameter              | Value          |
|------------------------|----------------|
| Replicas               | 12             |
| CPU request per pod    | 0.5 vCPU       |
| RAM request per pod    | 1 GiB          |

## Current cluster

| Node type    | vCPU | RAM   | On-demand price | Count |
|--------------|------|-------|-----------------|-------|
| m5.2xlarge   | 8    | 32 GiB | $0.384/hr       | 2     |

Kubernetes overhead: 10% of CPU and RAM reserved for system components.
  Effective allocatable per node: 8 × 0.9 = 7.2 vCPU, 32 × 0.9 = 28.8 GiB

## Right-sized option

| Node type  | vCPU | RAM  | On-demand price | Spot price  |
|------------|------|------|-----------------|-------------|
| m5.large   | 2    | 8 GiB | $0.096/hr      | $0.029/hr   |

Effective allocatable per m5.large: 2 × 0.9 = 1.8 vCPU, 8 × 0.9 = 7.2 GiB

Billing: 730 hours/month (AWS standard).

## Formulas

### Pod density

    pods_per_node = min(
        floor(allocatable_cpu   / pod_cpu_request),
        floor(allocatable_ram   / pod_ram_request),
    )

### Nodes needed

    nodes_needed = ceil(replicas / pods_per_node)

### Monthly cost (on-demand)

    monthly_cost = nodes_needed × price_per_hour × 730

### Mixed (50% on-demand, 50% spot)

    nodes_on_demand = ceil(nodes_needed / 2)
    nodes_spot      = nodes_needed - nodes_on_demand
    monthly_mixed   = (nodes_on_demand × od_price + nodes_spot × spot_price) × 730

## Your working (fill this in)

### Current cluster

    nodes = 2  (given)
    monthly = 2 × $0.384 × 730 = ???

### Right-sized (on-demand m5.large)

    allocatable_cpu   = ???
    allocatable_ram   = ???
    pods_per_node_cpu = floor(??? / 0.5)  = ???
    pods_per_node_ram = floor(??? / 1.0)  = ???
    pods_per_node     = min(???, ???)     = ???
    nodes_needed      = ceil(12 / ???)    = ???
    monthly           = ??? × $0.096 × 730 = ???

### Mixed (50/50 on-demand + spot m5.large)

    nodes_on_demand = ceil(??? / 2)       = ???
    nodes_spot      = ??? - ???           = ???
    monthly         = (??? × $0.096 + ??? × $0.029) × 730 = ???
MDEOF

# ── answers.py ───────────────────────────────────────────────────────────────
if [ ! -f "$WORK/answers.py" ]; then
cat > "$WORK/answers.py" << 'PYEOF'
# answers.py — compute the three cost figures and set the variables below.
# Run:  python3 checker.py
# Then: bash courses/course-34-managed-kubernetes/challenges/05-right-size-and-spot/verify.sh

current_monthly_cost    = 0.0   # $USD — current 2x m5.2xlarge on-demand, 730 h/month
rightsized_monthly_cost = 0.0   # $USD — right-sized to on-demand m5.large only
mixed_monthly_cost      = 0.0   # $USD — right-sized, 50% on-demand + 50% spot m5.large
PYEOF
fi

# ── checker.py ───────────────────────────────────────────────────────────────
cat > "$WORK/checker.py" << 'PYEOF'
#!/usr/bin/env python3
"""checker.py — validates right-sizing and spot cost estimates.

Reference derivation:
  Replicas: 12, pod: 0.5 vCPU + 1 GiB RAM, billing: 730 h/month

  --- current (2x m5.2xlarge @ $0.384/hr) ---
  current_monthly_cost = 2 * 0.384 * 730 = 560.64

  --- right-sized (m5.large @ $0.096/hr) ---
  allocatable_cpu = 2 * 0.9 = 1.8 vCPU
  allocatable_ram = 8 * 0.9 = 7.2 GiB
  pods_per_node   = min(floor(1.8/0.5), floor(7.2/1.0)) = min(3, 7) = 3
  nodes_needed    = ceil(12 / 3) = 4
  rightsized_monthly_cost = 4 * 0.096 * 730 = 280.32

  --- mixed (2 on-demand + 2 spot m5.large) ---
  nodes_on_demand = ceil(4 / 2) = 2
  nodes_spot      = 4 - 2 = 2
  mixed_monthly_cost = (2 * 0.096 + 2 * 0.029) * 730
                     = (0.192 + 0.058) * 730
                     = 0.250 * 730 = 182.50
"""
import sys

CORRECT = {
    "current_monthly_cost":    560.64,
    "rightsized_monthly_cost": 280.32,
    "mixed_monthly_cost":      182.50,
}
TOLERANCE = 0.10

try:
    import answers
except ImportError:
    print("answers.py not found in the current directory.")
    sys.exit(1)

MISSING = object()


def check(label, got, expected, tol, unit=""):
    if got is MISSING or got is None:
        print(f"  x  {label}: not set")
        return False
    lo, hi = expected * (1 - tol), expected * (1 + tol)
    if lo <= float(got) <= hi:
        print(f"  ok {label}: ${got:.2f}  (expected ~${expected:.2f}, ±{int(tol*100)}%)")
        return True
    print(f"  x  {label}: ${got:.2f}  (expected ${lo:.2f}–${hi:.2f})")
    return False


results = [
    check("current_monthly_cost",    getattr(answers, "current_monthly_cost",    MISSING), CORRECT["current_monthly_cost"],    TOLERANCE),
    check("rightsized_monthly_cost", getattr(answers, "rightsized_monthly_cost", MISSING), CORRECT["rightsized_monthly_cost"], TOLERANCE),
    check("mixed_monthly_cost",      getattr(answers, "mixed_monthly_cost",      MISSING), CORRECT["mixed_monthly_cost"],      TOLERANCE),
]

if all(results):
    savings = getattr(answers, "current_monthly_cost", CORRECT["current_monthly_cost"])
    mixed   = getattr(answers, "mixed_monthly_cost",   CORRECT["mixed_monthly_cost"])
    try:
        pct = (float(savings) - float(mixed)) / float(savings) * 100
        print(f"\n  Total savings with right-size + spot: {pct:.1f}%")
    except Exception:
        pass
    print("\nAll estimates within tolerance.")
    sys.exit(0)
else:
    print("\nOne or more estimates are off. Re-read scenario.md and recheck your arithmetic.")
    sys.exit(1)
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Files:"
echo "  scenario.md   — workload spec, pricing table, formula guide"
echo "  answers.py    — set the three cost variables here"
echo "  checker.py    — run to see which values pass"
echo
echo "Quick start:"
echo "  cd $WORK && python3 checker.py"
echo
echo "Verify + flag:"
echo "  bash courses/course-34-managed-kubernetes/challenges/05-right-size-and-spot/verify.sh"
