#!/usr/bin/env bash
# Persisted, re-runnable coverage for generate-certs.sh. This replaces the ephemeral,
# run-and-discard local proof from Task 1 (see
# .superpowers/sdd/2026-08-08-kthw-phase2-pki-bootstrap/task-1-report.md) with a
# committed test, using the same technique: a scratch $HOME, a stub `aws` on PATH
# that logs calls and exits 0, and a ca.conf rendered via `terraform console`.
#
# Three checks, each must pass for this script to exit 0:
#   1. First run: full pipeline succeeds, all 7 cert files exist.
#   2. Second run against the SAME scratch $HOME (certs/ not wiped between runs)
#      preserves the existing CA (D6) — this is the coverage the final review
#      found missing. Asserts the "already exists" skip message appears and
#      ca.crt's sha256 is byte-identical before and after.
#   3. A corrupted ca.conf (bad kube-proxy O= field) in a FRESH scratch dir is
#      rejected: exit 1 and the expected FAIL: message.
#
# Does not touch real AWS. Does not require terraform.tfvars (every root variable
# has a default).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GENERATE_CERTS="${SCRIPT_DIR}/generate-certs.sh"

CERT_NAMES=(ca admin kube-proxy kube-scheduler kube-controller-manager kube-api-server service-accounts)

REGION="eu-north-1"
SERVER_IP="10.240.1.99"
SSM_PARAM_NAME="/kthw/ca.crt"

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

# A stub `aws` that logs every invocation and exits 0 unconditionally. This makes
# `aws sts get-caller-identity` succeed on the first try, so generate-certs.sh's
# credential-wait retry loop breaks immediately instead of spinning for up to a
# minute, and makes `aws ssm put-parameter` a no-op we can inspect via the log.
make_stub_aws() {
  local bin_dir="$1"
  local log_file="$2"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/aws" <<STUB
#!/usr/bin/env bash
echo "aws \$*" >>"${log_file}"
exit 0
STUB
  chmod +x "${bin_dir}/aws"
}

# Renders ca.conf.template the same way Terraform's templatefile() call in main.tf
# does, but via \`terraform console\` against dummy values, exactly as Task 1's
# local proof did. terraform console wraps multi-line string results in a
# <<EOT ... EOT heredoc marker, so those first/last lines are stripped.
render_ca_conf() {
  local dest="$1"
  local server_ip="$2"
  (
    cd "${TERRAFORM_DIR}" || exit 1
    echo "templatefile(\"scripts/ca.conf.template\", { service_cluster_ip = \"10.32.0.1\", server_private_ip = \"${server_ip}\" })" \
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
echo "Check 1: first run succeeds and produces all 7 cert files"
echo "=================================================================="

SCRATCH1="$(mktemp -d)"
CLEANUP_DIRS+=("${SCRATCH1}")
BIN1="${SCRATCH1}/bin"
LOG1="${SCRATCH1}/aws-calls.log"
make_stub_aws "${BIN1}" "${LOG1}"
render_ca_conf "${SCRATCH1}/ca.conf" "${SERVER_IP}"

RUN1_OUTPUT="$(HOME="${SCRATCH1}" PATH="${BIN1}:${PATH}" \
  REGION="${REGION}" SERVER_IP="${SERVER_IP}" SSM_PARAM_NAME="${SSM_PARAM_NAME}" \
  "${GENERATE_CERTS}" 2>&1)"
RUN1_RC=$?
echo "${RUN1_OUTPUT}"

if [[ "${RUN1_RC}" -eq 0 ]]; then
  note_pass "first run exited 0"
else
  note_fail "first run exited ${RUN1_RC}, expected 0"
fi

if all_cert_files_exist "${SCRATCH1}/certs"; then
  note_pass "all 7 cert files exist after first run"
else
  note_fail "not all 7 cert files exist after first run"
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
  REGION="${REGION}" SERVER_IP="${SERVER_IP}" SSM_PARAM_NAME="${SSM_PARAM_NAME}" \
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
LOG3="${SCRATCH3}/aws-calls.log"
make_stub_aws "${BIN3}" "${LOG3}"
render_ca_conf "${SCRATCH3}/ca.conf" "${SERVER_IP}"

# Corrupt kube-proxy's O= identity field, same technique as Task 1's negative test.
sed -i 's/^O  = system:node-proxier$/O  = system:wrong-proxier/' "${SCRATCH3}/ca.conf"
if ! grep -q 'O  = system:wrong-proxier' "${SCRATCH3}/ca.conf"; then
  note_fail "failed to corrupt ca.conf for the negative test (sed did not match)"
fi

RUN3_OUTPUT="$(HOME="${SCRATCH3}" PATH="${BIN3}:${PATH}" \
  REGION="${REGION}" SERVER_IP="${SERVER_IP}" SSM_PARAM_NAME="${SSM_PARAM_NAME}" \
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
