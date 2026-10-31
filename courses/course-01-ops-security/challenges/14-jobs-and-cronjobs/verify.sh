#!/usr/bin/env bash
# Verifier for "Batch It". Confirms a Job actually succeeded AND a CronJob with
# a valid schedule exists in dojo-batch. Prints the flag only when both hold.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-batch
FLAG='KUBE{batch_work_runs_to_completion}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# 1) At least one Job exists AND at least one has status.succeeded >= 1.
JOBNAMES=$(kubectl -n "$NS" get jobs -o name 2>/dev/null)
[ -n "$JOBNAMES" ] || fail "no Job found in $NS — create one that runs to completion"

SUCCEEDED=0
for s in $(kubectl -n "$NS" get jobs -o jsonpath='{.items[*].status.succeeded}' 2>/dev/null); do
  if [ "$s" -ge 1 ] 2>/dev/null; then SUCCEEDED=1; fi
done
[ "$SUCCEEDED" -eq 1 ] || fail "a Job exists but none have succeeded yet (status.succeeded < 1) — wait for the pod to exit 0, or fix a non-zero exit"

# 2) At least one CronJob exists with a non-empty, valid schedule.
CRON=$(kubectl -n "$NS" get cronjob -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$CRON" ] || fail "no CronJob found in $NS — create one (e.g. schedule '*/1 * * * *')"

SCHED=$(kubectl -n "$NS" get cronjob "$CRON" -o jsonpath='{.spec.schedule}' 2>/dev/null)
[ -n "$SCHED" ] || fail "CronJob '$CRON' has an empty schedule"

# Valid = a macro (@hourly, @daily, ...) OR exactly 5 whitespace-separated fields.
case "$SCHED" in
  @*)
    : ;;                      # cron macro — accepted
  *)
    set -f                    # disable globbing: a '*' field must not expand to filenames
    # shellcheck disable=SC2086
    set -- $SCHED
    set +f
    [ "$#" -eq 5 ] || fail "schedule '$SCHED' is not valid (need 5 cron fields or an @macro)"
    ;;
esac

echo "✓ Job succeeded            : yes (status.succeeded >= 1)"
echo "✓ CronJob present           : $CRON"
echo "✓ CronJob schedule valid    : '$SCHED'"
echo
echo "Batch checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
