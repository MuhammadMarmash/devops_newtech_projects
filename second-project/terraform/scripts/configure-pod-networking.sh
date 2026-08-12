#!/usr/bin/env bash
set -euo pipefail

: "${REGION:?REGION must be set}"
: "${ROUTE_TABLE_ID:?ROUTE_TABLE_ID must be set}"
: "${NODE_DATA:?NODE_DATA must be set}"

cd "$HOME"

IFS=',' read -ra ENTRIES <<< "${NODE_DATA}"
for entry in "${ENTRIES[@]}"; do
  name="${entry%%=*}"
  rest="${entry#*=}"
  ip="${rest%%=*}"
  eni="${rest#*=}"

  echo "Waiting for ${name}'s pod CIDR"
  PODCIDR=""
  for _ in $(seq 1 24); do
    PODCIDR="$(kubectl get node "${name}" -o jsonpath='{.spec.podCIDR}' --kubeconfig certs/admin.kubeconfig 2>/dev/null || true)"
    if [[ -n "${PODCIDR}" ]]; then
      break
    fi
    sleep 5
  done
  if [[ -z "${PODCIDR}" ]]; then
    echo "FAIL: ${name} never received a podCIDR" >&2
    exit 1
  fi
  echo "${name} podCIDR: ${PODCIDR}"

  sed "s|SUBNET|${PODCIDR}|g" 10-bridge.conf.template > "10-bridge-${name}.conf"

  scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "10-bridge-${name}.conf" "admin@${ip}:/tmp/10-bridge.conf"
  ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${ip}" \
    "sudo mv /tmp/10-bridge.conf /etc/cni/net.d/10-bridge.conf"

  echo "Creating route for ${PODCIDR} via ${eni}"
  if ! CREATE_OUTPUT=$(aws ec2 create-route \
    --region "${REGION}" \
    --route-table-id "${ROUTE_TABLE_ID}" \
    --destination-cidr-block "${PODCIDR}" \
    --network-interface-id "${eni}" 2>&1); then
    if echo "${CREATE_OUTPUT}" | grep -q "RouteAlreadyExists"; then
      echo "route for ${PODCIDR} already exists — skipping"
    else
      echo "${CREATE_OUTPUT}" >&2
      exit 1
    fi
  fi
done
