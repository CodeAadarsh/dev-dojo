#!/usr/bin/env bash
# Plants the "RAG Citation" challenge: a knowledge base with the flag embedded
# in a specific chunk, plus a Python skeleton for chunking and retrieval.
set -euo pipefail

SLUG="03-rag-citation"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ---- requirements.txt ------------------------------------------------------
cat > "$WORK/requirements.txt" << 'EOF'
pytest
EOF

# ---- knowledge_base.txt (flag embedded in the postmortem section) -----------
cat > "$WORK/knowledge_base.txt" << 'EOF'
# SRE Principles and Practices — Internal Wiki

## Error Budget Policy

An error budget is the acceptable amount of unreliability permitted within an SLO window — typically 30 days. If availability target is 99.9%, the error budget is 0.1% of that window, or roughly 43 minutes of downtime per month. Error budgets make the reliability trade-off explicit: teams can spend budget on velocity (risky deployments, experiments) or preserve it for stability. When the budget is exhausted, the incident response team has standing authority to freeze non-critical deployments until the window resets. Budget burn rate alerts — triggering at 1×, 2×, and 5× the expected burn rate — give early warning before the budget is fully consumed.

## SLO and SLI Design

A Service Level Indicator (SLI) is a quantitative measure of service behaviour: request latency at p99, error rate on the critical path, availability measured at the load balancer. An SLO is a target range for an SLI over a rolling window. Well-designed SLOs have four properties: they measure what the user actually experiences (not internal health checks), they use a long enough window to smooth noise (28–30 days), they are set just tight enough to motivate action when breached but not so tight that teams spend all their time firefighting, and they are agreed on by both engineering and product. Common mistakes are latency SLOs that measure median rather than p99 (the median can look fine while 1% of users are experiencing 10-second timeouts) and availability SLOs defined on synthetic probes rather than real user traffic.

## Alerting Strategy

Good alerts have three properties: they are actionable, they are urgent, and they are relevant. Alerts that fire without a clear runbook action degrade on-call quality faster than almost anything else — engineers learn to ignore them. Every alert should have a linked runbook that answers: what does this alert mean, how do I confirm it is real, what are the first three steps to mitigate, and who should I escalate to? Page-level alerts (wake someone up) should be reserved for conditions that are impacting users right now or will within minutes. Warning-level alerts (send a ticket, no page) are for conditions that will become urgent if unaddressed within hours. Runbook links belong in the alert body, not in the team Slack channel, so the on-call engineer who has never seen this alert before can act without context.

## On-Call Rotation Design

A healthy on-call rotation has: no more than one in six weeks of primary on-call per engineer (more frequent than that and cognitive load degrades code quality), explicit handoff meetings at shift boundaries to transfer context on open incidents, shadowing for new team members before they take primary, and a weekly review of alert noise. Alert noise review is the highest-leverage 30 minutes of the week: cancelling or raising thresholds on alerts that fired without action in the past month dramatically reduces on-call fatigue. Measure mean time to acknowledge (MTTA) and mean time to resolve (MTTR) per service; an MTTA above 15 minutes or an MTTR above four hours on Severity-1 incidents is a signal that either the runbooks or the rotation staffing needs work.

## Incident Command Structure

During a live incident, a clear command structure prevents the two failure modes that kill MTTR: too many people making independent changes that interfere with each other, and nobody making decisions because everyone is waiting for someone else. The incident commander (IC) owns the timeline and communication cadence; they do not debug. The responder (or responders) own the technical investigation; they communicate findings to the IC, not to the stakeholder channel directly. A scribe logs every hypothesis, action taken, and rollback attempt with timestamps in a shared doc — this is the raw material for the postmortem and also the insurance policy if a change made under pressure introduced a secondary failure. Stakeholder updates go out on a fixed cadence (every 15–30 minutes for Sev-1) from the IC, not ad-hoc from whoever is least busy.

## Blameless Post-Incident Review

A blameless postmortem is the cornerstone of a learning organisation. After every Severity-1 or Severity-2 incident, schedule a structured review within 48 hours while memory is fresh. The meeting should include the incident commander, all responders, and one representative from any affected downstream team. Focus on systems, processes, and communication gaps — never individuals. The goal is not to assign blame but to understand the conditions that made the failure possible and to prevent recurrence.

The five sections of an effective blameless postmortem are: (1) incident summary with severity, customer impact, and duration; (2) detailed timeline from first signal to full resolution, annotated with root-cause identification; (3) contributing factors — the systemic conditions (missing monitoring, insufficient testing, unclear ownership) that allowed the failure to happen; (4) what went well, because a blameless culture acknowledges what the team did right under pressure; and (5) concrete action items with owners and due dates, linked to the error budget policy so the team knows the consequence of not completing them. Post the document to a shared engineering channel within 72 hours so the whole organisation learns from the failure, not just the team involved. FLAG=KUBE{rag_retrieves_the_right_chunk}

## Deployment and Change Management

The majority of production incidents trace back to a recent change — a code deploy, a configuration update, a dependency version bump, a database migration. The primary risk-reduction tools are: feature flags (decouple deploy from release; roll back with a config change, not a revert+deploy), canary deployments (route 1–5% of traffic to the new version first; promote only after metrics are stable), and automated rollback triggers (if error rate exceeds 2× baseline within 15 minutes of a deploy, roll back without human intervention). Change freeze windows around high-traffic periods (Black Friday, major product launches, end-of-quarter) are not a substitute for good deployment practices — they are a fallback for teams that haven't invested in safe deployment tooling yet.

## Chaos Engineering

Chaos engineering is the practice of deliberately injecting failures into a system to verify that it tolerates them gracefully. The key word is "verify" — chaos is not about breaking things at random; it is about confirming that the resilience mechanisms you believe are in place actually work. A chaos experiment has a hypothesis ("if we terminate one pod in the payments service, traffic will shift to the remaining pods within 30 seconds and the error rate will remain below 0.1%"), a blast radius limit (run in staging first, then in production with traffic limited to a small fraction), a defined abort condition, and a clear owner. The most valuable experiments are the ones that reveal a gap between the documented architecture and the actual behaviour — a missing circuit breaker, a retry storm that wasn't visible in load tests, a graceful-shutdown timeout set too low.
EOF

# ---- skeleton: solution.py -------------------------------------------------
cat > "$WORK/solution.py" << 'PYEOF'
"""
RAG Citation — chunk a knowledge base and retrieve the most relevant passage.

The knowledge base is in knowledge_base.txt in the same directory.
Implement chunk_text() and retrieve(), then call them to find the chunk
that answers the target question. The flag is inside that chunk.
"""

import math
import re


# ---------------------------------------------------------------------------
# Step 1: chunking
# ---------------------------------------------------------------------------

def chunk_text(text: str, max_words: int = 120, overlap: int = 20) -> list:
    """
    Split text into overlapping chunks of approximately max_words words.

    A simple paragraph-level split also works — feel free to replace this
    with any strategy that produces coherent, non-empty segments.

    Args:
        text:      the full document text
        max_words: target size of each chunk in words
        overlap:   words of overlap between consecutive chunks

    Returns:
        A list of non-empty string chunks.
    """
    raise NotImplementedError("implement chunk_text")


# ---------------------------------------------------------------------------
# Step 2: retrieval
# ---------------------------------------------------------------------------

def retrieve(question: str, chunks: list) -> str:
    """
    Return the single most relevant chunk for the given question.

    Scoring approach: TF-IDF, keyword overlap, bag-of-words cosine, or
    anything else that produces a numeric similarity score per chunk.

    Args:
        question: the query string
        chunks:   list of text chunks from chunk_text()

    Returns:
        The chunk string with the highest relevance score.
    """
    raise NotImplementedError("implement retrieve")


# ---------------------------------------------------------------------------
# Entrypoint — run to find the flag
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    with open("knowledge_base.txt") as f:
        text = f.read()

    chunks = chunk_text(text)
    print(f"Chunked into {len(chunks)} segments.")

    question = "What are the five sections of an effective blameless post-incident review?"
    top_chunk = retrieve(question, chunks)

    print("\n--- Top chunk ---")
    print(top_chunk)

    match = re.search(r'FLAG=(KUBE\{[^}]+\})', top_chunk)
    if match:
        print("\nFlag found:", match.group(1))
    else:
        print("\nFlag not found in top chunk — retrieval returned the wrong passage.")
PYEOF

echo "Workspace: $WORK"
echo
echo "Task: implement chunk_text() and retrieve() in $WORK/solution.py"
echo "      Run 'python3 solution.py' from $WORK to find the flag."
echo
echo "Question to answer: 'What are the five sections of an effective blameless post-incident review?'"
echo
echo "Prereqs: python3 (standard library only — no extra packages needed for a basic solution)"
echo "  Optional (for embedding-based retrieval): ollama pull llama3.2"
