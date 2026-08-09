#!/usr/bin/env bash
set -euo pipefail

: "${REGION:?REGION must be set}"
: "${SERVER_IP:?SERVER_IP must be set}"
: "${SSM_PARAM_NAME:?SSM_PARAM_NAME must be set}"
: "${NODE_IPS:?NODE_IPS must be set}"

cd "$HOME"
mkdir -p certs
cd certs

NODE_NAMES=()
declare -A NODE_IP
IFS=',' read -ra PAIRS <<< "${NODE_IPS}"
for pair in "${PAIRS[@]}"; do
  name="${pair%%=*}"
  ip="${pair#*=}"
  NODE_NAMES+=("${name}")
  NODE_IP["${name}"]="${ip}"
done

if [[ ! -x /usr/local/bin/kubectl ]]; then
  curl -fsSL -o /tmp/kubectl https://dl.k8s.io/v1.32.3/bin/linux/amd64/kubectl
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
fi

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

CERTS=(admin kube-proxy kube-scheduler kube-controller-manager kube-api-server service-accounts "${NODE_NAMES[@]}")

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

for name in "${NODE_NAMES[@]}"; do
  EXPECT_CN["${name}"]="system:node:${name}"
  EXPECT_O["${name}"]="system:nodes"
done

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
  --description "Cluster CA certificate; written by the Phase 2 orchestrator" \
  --overwrite \
  --value "$(cat ca.crt)"

echo "Building kubeconfigs"

build_kubeconfig() {
  local user="$1" cert="$2" key="$3" out="$4"
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server="https://${SERVER_IP}:6443" \
    --kubeconfig="${out}"
  kubectl config set-credentials "${user}" \
    --client-certificate="${cert}" \
    --client-key="${key}" \
    --embed-certs=true \
    --kubeconfig="${out}"
  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user="${user}" \
    --kubeconfig="${out}"
  kubectl config use-context default --kubeconfig="${out}"
}

for name in "${NODE_NAMES[@]}"; do
  build_kubeconfig "system:node:${name}" "${name}.crt" "${name}.key" "${name}.kubeconfig"
done
build_kubeconfig system:kube-proxy kube-proxy.crt kube-proxy.key kube-proxy.kubeconfig
build_kubeconfig system:kube-controller-manager kube-controller-manager.crt kube-controller-manager.key kube-controller-manager.kubeconfig
build_kubeconfig system:kube-scheduler kube-scheduler.crt kube-scheduler.key kube-scheduler.kubeconfig
build_kubeconfig admin admin.crt admin.key admin.kubeconfig

echo "Distributing node certificates and kubeconfigs"
for name in "${NODE_NAMES[@]}"; do
  ip="${NODE_IP[${name}]}"
  ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${ip}" "sudo mkdir -p /var/lib/kubelet /var/lib/kube-proxy"
  scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no ca.crt "admin@${ip}:/tmp/ca.crt"
  scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "${name}.crt" "admin@${ip}:/tmp/kubelet.crt"
  scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "${name}.key" "admin@${ip}:/tmp/kubelet.key"
  scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "${name}.kubeconfig" "admin@${ip}:/tmp/kubelet-kubeconfig"
  scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no kube-proxy.kubeconfig "admin@${ip}:/tmp/kube-proxy-kubeconfig"
  ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${ip}" \
    "sudo mv /tmp/ca.crt /tmp/kubelet.crt /tmp/kubelet.key /var/lib/kubelet/ && \
     sudo mv /tmp/kubelet-kubeconfig /var/lib/kubelet/kubeconfig && \
     sudo mv /tmp/kube-proxy-kubeconfig /var/lib/kube-proxy/kubeconfig && \
     sudo chown root:root /var/lib/kubelet/ca.crt /var/lib/kubelet/kubelet.crt /var/lib/kubelet/kubelet.key /var/lib/kubelet/kubeconfig /var/lib/kube-proxy/kubeconfig"
done

echo "Distributing server-side kubeconfigs"
scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no \
  admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig \
  "admin@${SERVER_IP}:~/"

echo "Phase 2 cert bootstrap complete"
