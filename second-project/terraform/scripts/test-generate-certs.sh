#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GENERATE_CERTS="${SCRIPT_DIR}/generate-certs.sh"

CERT_NAMES=(ca admin kube-proxy kube-scheduler kube-controller-manager kube-api-server service-accounts node-0 node-1)

REGION="eu-north-1"
SERVER_IP="10.240.1.99"
SSM_PARAM_NAME="/kthw/ca.crt"
NODE_IPS="node-0=10.240.1.11,node-1=10.240.1.12"

CLEANUP_DIRS=()
cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]}"; do
    rm -rf "${d}"
  done
}
trap cleanup EXIT

FAILURES=0
note_pass() { echo "PASS: $1"; }
note_fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

make_stub_remote_tools() {
  local bin_dir="$1"
  local log_file="$2"
  mkdir -p "${bin_dir}"
  for tool in aws ssh scp; do
    cat >"${bin_dir}/${tool}" <<STUB
#!/usr/bin/env bash
echo "${tool} \$*" >>"${log_file}"
exit 0
STUB
    chmod +x "${bin_dir}/${tool}"
  done
}

render_ca_conf() {
  local dest="$1"
  local server_ip="$2"
  (
    cd "${TERRAFORM_DIR}" || exit 1
    echo "templatefile(\"scripts/ca.conf.template\", { service_cluster_ip = \"10.32.0.1\", server_private_ip = \"${server_ip}\", worker_ips = { \"node-0\" = \"10.240.1.11\", \"node-1\" = \"10.240.1.12\" } })" \
      | terraform console
  ) | sed '1d;$d' >"${dest}"
}

all_cert_files_exist() {
  local certs_dir="$1"
  local name
  for name in "${CERT_NAMES[@]}"; do
    if [[ ! -f "${certs_dir}/${name}.crt" ]]; then
      return 1
    fi
  done
  return 0
}

echo "=================================================================="
echo "Check 1: first run succeeds and produces all cert files"
echo "=================================================================="

SCRATCH1="$(mktemp -d)"
CLEANUP_DIRS+=("${SCRATCH1}")
BIN1="${SCRATCH1}/bin"
LOG1="${SCRATCH1}/calls.log"
make_stub_remote_tools "${BIN1}" "${LOG1}"
curl -fsSL -o "${BIN1}/kubectl" https://dl.k8s.io/v1.32.3/bin/linux/amd64/kubectl
chmod +x "${BIN1}/kubectl"
render_ca_conf "${SCRATCH1}/ca.conf" "${SERVER_IP}"

RUN1_OUTPUT="$(HOME="${SCRATCH1}" PATH="${BIN1}:${PATH}" \
  REGION="${REGION}" SERVER_IP="${SERVER_IP}" SSM_PARAM_NAME="${SSM_PARAM_NAME}" NODE_IPS="${NODE_IPS}" \
  "${GENERATE_CERTS}" 2>&1)"
RUN1_RC=$?
echo "${RUN1_OUTPUT}"

if [[ "${RUN1_RC}" -eq 0 ]]; then
  note_pass "first run exited 0"
else
  note_fail "first run exited ${RUN1_RC}, expected 0"
fi

if all_cert_files_exist "${SCRATCH1}/certs"; then
  note_pass "all cert files exist after first run"
else
  note_fail "not all cert files exist after first run"
fi

if [[ -f "${SCRATCH1}/certs/admin.kubeconfig" && -f "${SCRATCH1}/certs/kube-proxy.kubeconfig" && -f "${SCRATCH1}/certs/node-0.kubeconfig" ]]; then
  note_pass "kubeconfigs were built for admin, kube-proxy, and node-0"
else
  note_fail "expected kubeconfig files are missing"
fi

if grep -q "https://${SERVER_IP}:6443" "${SCRATCH1}/certs/admin.kubeconfig"; then
  note_pass "admin.kubeconfig points at the correct server address"
else
  note_fail "admin.kubeconfig does not reference https://${SERVER_IP}:6443"
fi

if grep -q "scp .*admin.kubeconfig.*admin@${SERVER_IP}" "${LOG1}"; then
  note_pass "server-side kubeconfigs were distributed to the server IP"
else
  note_fail "server-side kubeconfig distribution not found in the stub log"
fi

if grep -q "scp .*node-0.crt admin@10.240.1.11:/tmp/kubelet.crt" "${LOG1}" \
  && grep -q "scp .*node-1.crt admin@10.240.1.12:/tmp/kubelet.crt" "${LOG1}"; then
  note_pass "node certs were distributed to both node IPs"
else
  note_fail "node cert distribution calls not found in the stub log"
fi

echo
echo "=================================================================="
echo "Check 2: second run against the same scratch \$HOME preserves the CA"
echo "=================================================================="

CA_SHA_BEFORE="$(sha256sum "${SCRATCH1}/certs/ca.crt" 2>/dev/null | awk '{print $1}')"
if [[ -z "${CA_SHA_BEFORE}" ]]; then
  note_fail "could not compute sha256 of ca.crt after first run (file missing?)"
fi

RUN2_OUTPUT="$(HOME="${SCRATCH1}" PATH="${BIN1}:${PATH}" \
  REGION="${REGION}" SERVER_IP="${SERVER_IP}" SSM_PARAM_NAME="${SSM_PARAM_NAME}" NODE_IPS="${NODE_IPS}" \
  "${GENERATE_CERTS}" 2>&1)"
RUN2_RC=$?
echo "${RUN2_OUTPUT}"

if [[ "${RUN2_RC}" -eq 0 ]]; then
  note_pass "second run exited 0"
else
  note_fail "second run exited ${RUN2_RC}, expected 0"
fi

if grep -q "already exists" <<<"${RUN2_OUTPUT}"; then
  note_pass "second run printed the CA-preservation skip message"
else
  note_fail "second run did not print the expected 'already exists' skip message"
fi

CA_SHA_AFTER="$(sha256sum "${SCRATCH1}/certs/ca.crt" 2>/dev/null | awk '{print $1}')"
if [[ -n "${CA_SHA_BEFORE}" && "${CA_SHA_BEFORE}" == "${CA_SHA_AFTER}" ]]; then
  note_pass "ca.crt is byte-identical before and after the second run (sha256 ${CA_SHA_AFTER})"
else
  note_fail "ca.crt changed across the second run (before=${CA_SHA_BEFORE} after=${CA_SHA_AFTER})"
fi

echo
echo "=================================================================="
echo "Check 3: a corrupted ca.conf is rejected"
echo "=================================================================="

SCRATCH3="$(mktemp -d)"
CLEANUP_DIRS+=("${SCRATCH3}")
BIN3="${SCRATCH3}/bin"
LOG3="${SCRATCH3}/calls.log"
make_stub_remote_tools "${BIN3}" "${LOG3}"
curl -fsSL -o "${BIN3}/kubectl" https://dl.k8s.io/v1.32.3/bin/linux/amd64/kubectl
chmod +x "${BIN3}/kubectl"
render_ca_conf "${SCRATCH3}/ca.conf" "${SERVER_IP}"

sed -i 's/^O  = system:node-proxier$/O  = system:wrong-proxier/' "${SCRATCH3}/ca.conf"
if ! grep -q 'O  = system:wrong-proxier' "${SCRATCH3}/ca.conf"; then
  note_fail "failed to corrupt ca.conf for the negative test (sed did not match)"
fi

RUN3_OUTPUT="$(HOME="${SCRATCH3}" PATH="${BIN3}:${PATH}" \
  REGION="${REGION}" SERVER_IP="${SERVER_IP}" SSM_PARAM_NAME="${SSM_PARAM_NAME}" NODE_IPS="${NODE_IPS}" \
  "${GENERATE_CERTS}" 2>&1)"
RUN3_RC=$?
echo "${RUN3_OUTPUT}"

if [[ "${RUN3_RC}" -eq 1 ]]; then
  note_pass "corrupted-config run exited 1"
else
  note_fail "corrupted-config run exited ${RUN3_RC}, expected 1"
fi

if grep -q "FAIL: kube-proxy expected O=system:node-proxier" <<<"${RUN3_OUTPUT}"; then
  note_pass "corrupted-config run printed the expected FAIL message"
else
  note_fail "corrupted-config run did not print the expected FAIL: kube-proxy expected O=system:node-proxier message"
fi

echo
echo "=================================================================="
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "SUMMARY: all checks passed"
  exit 0
else
  echo "SUMMARY: ${FAILURES} check(s) failed"
  exit 1
fi
