#!/usr/bin/env bash
set -euo pipefail

AZS=("eu-north-1a" "eu-north-1b" "eu-north-1c")
ROUNDS=5
SLEEP_BETWEEN_ROUNDS=60

export AWS_MAX_ATTEMPTS=3

LOG="$(mktemp)"
trap 'rm -f "${LOG}"' EXIT

for round in $(seq 1 "${ROUNDS}"); do
  for az in "${AZS[@]}"; do
    echo "=================================================================="
    echo "Round ${round}/${ROUNDS} — trying availability_zone=${az}"
    echo "=================================================================="
    if terraform apply -auto-approve -var="availability_zone=${az}" -var="jumpbox_instance_type=t3.small" 2>&1 | tee "${LOG}"; then
      echo "Succeeded in ${az}"
      exit 0
    fi
    if grep -q "InsufficientInstanceCapacity" "${LOG}"; then
      echo "Capacity error in ${az} — trying the next availability zone"
      continue
    fi
    echo "Non-capacity error — stopping instead of trying another AZ" >&2
    exit 1
  done
  if [[ "${round}" -lt "${ROUNDS}" ]]; then
    echo "All availability zones tight this round — waiting ${SLEEP_BETWEEN_ROUNDS}s before round $((round + 1))"
    sleep "${SLEEP_BETWEEN_ROUNDS}"
  fi
done

echo "All ${ROUNDS} rounds exhausted across ${AZS[*]} — no capacity found" >&2
exit 1
