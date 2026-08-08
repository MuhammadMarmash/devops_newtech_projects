#!/usr/bin/env bash
# Provisions the KTHW CA and control-plane certificates, following the exact openssl
# commands from github.com/kelseyhightower/kubernetes-the-hard-way's
# docs/04-certificate-authority.md. Runs on the jumpbox via a Terraform remote-exec
# provisioner (see terraform/main.tf, null_resource.cert_bootstrap).
set -euo pipefail

: "${REGION:?REGION must be set}"
: "${SERVER_IP:?SERVER_IP must be set}"
: "${SSM_PARAM_NAME:?SSM_PARAM_NAME must be set}"

cd "$HOME"
mkdir -p certs
cd certs

if [[ -f ca.key ]]; then
  echo "ca.key already exists on this jumpbox — skipping CA generation to avoid invalidating certs already signed by it"
else
  echo "Generating CA"
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -sha512 -noenc \
    -key ca.key -days 3653 \
    -config ../ca.conf \
    -out ca.crt
fi

CERTS=(admin kube-proxy kube-scheduler kube-controller-manager kube-api-server service-accounts)

for name in "${CERTS[@]}"; do
  echo "Signing ${name}"
  openssl genrsa -out "${name}.key" 4096

  openssl req -new -key "${name}.key" -sha256 \
    -config ../ca.conf -section "${name}" \
    -out "${name}.csr"

  openssl x509 -req -days 3653 -in "${name}.csr" \
    -copy_extensions copyall \
    -sha256 -CA ca.crt -CAkey ca.key \
    -CAcreateserial \
    -out "${name}.crt"
done

echo "Verifying signatures"
for name in "${CERTS[@]}"; do
  openssl verify -CAfile ca.crt "${name}.crt"
done

declare -A EXPECT_CN=(
  [admin]="admin"
  [kube-proxy]="system:kube-proxy"
  [kube-scheduler]="system:kube-scheduler"
  [kube-controller-manager]="system:kube-controller-manager"
  [kube-api-server]="kubernetes"
  [service-accounts]="service-accounts"
)
declare -A EXPECT_O=(
  [admin]="system:masters"
  [kube-proxy]="system:node-proxier"
  [kube-scheduler]="system:system:kube-scheduler"
  [kube-controller-manager]="system:kube-controller-manager"
)

echo "Verifying CN/O fields"
for name in "${CERTS[@]}"; do
  subject=$(openssl x509 -noout -subject -nameopt multiline -in "${name}.crt")
  echo "${name}:"
  echo "${subject}"

  echo "${subject}" | grep -qE "^ *commonName *= *${EXPECT_CN[$name]}\$" || {
    echo "FAIL: ${name} expected CN=${EXPECT_CN[$name]}" >&2
    exit 1
  }

  if [[ -n "${EXPECT_O[$name]:-}" ]]; then
    echo "${subject}" | grep -qE "^ *organizationName *= *${EXPECT_O[$name]}\$" || {
      echo "FAIL: ${name} expected O=${EXPECT_O[$name]}" >&2
      exit 1
    }
  fi
done

echo "Verifying kube-api-server SANs"
sans=$(openssl x509 -noout -ext subjectAltName -in kube-api-server.crt)
echo "${sans}"
for expected in "127.0.0.1" "10.32.0.1" "${SERVER_IP}"; do
  if [[ "${sans}" != *"${expected}"* ]]; then
    echo "FAIL: kube-api-server.crt is missing SAN ${expected}" >&2
    exit 1
  fi
done

echo "Waiting for instance-profile credentials to propagate"
for _ in $(seq 1 12); do
  aws sts get-caller-identity --region "${REGION}" >/dev/null 2>&1 && break
  sleep 5
done

echo "Publishing ca.crt to ${SSM_PARAM_NAME}"
aws ssm put-parameter \
  --region "${REGION}" \
  --name "${SSM_PARAM_NAME}" \
  --type String \
  --overwrite \
  --value "$(cat ca.crt)"

echo "Phase 2 cert bootstrap complete"
