#!/usr/bin/env bash
set -euo pipefail

: "${WORKER_IP:?WORKER_IP must be set}"
: "${WORKER_NAME:?WORKER_NAME must be set}"

cd "$HOME"

KUBELET_ACTIVE="$(ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${WORKER_IP}" \
  'systemctl is-active --quiet kubelet && echo yes || echo no')"
NODE_REGISTERED="no"
if kubectl get node "${WORKER_NAME}" --kubeconfig certs/admin.kubeconfig >/dev/null 2>&1; then
  NODE_REGISTERED="yes"
fi

if [[ "${KUBELET_ACTIVE}" == "yes" && "${NODE_REGISTERED}" == "yes" ]]; then
  echo "kubelet is already active and ${WORKER_NAME} is already registered — skipping worker bootstrap"
  exit 0
fi

sed "s|NODENAME|${WORKER_NAME}|g" kubelet.service.template > kubelet.service

ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${WORKER_IP}" "mkdir -p cni-plugins"

scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no \
  downloads/worker/kubelet downloads/worker/kube-proxy downloads/worker/containerd \
  downloads/worker/containerd-shim-runc-v2 downloads/worker/containerd-stress \
  downloads/worker/runc downloads/worker/crictl \
  99-loopback.conf containerd-config.toml kubelet-config.yaml kube-proxy-config.yaml \
  containerd.service kubelet.service kube-proxy.service \
  "admin@${WORKER_IP}:~/"

scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no \
  downloads/cni-plugins/* \
  "admin@${WORKER_IP}:~/cni-plugins/"

ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${WORKER_IP}" bash -s <<'REMOTE'
set -euo pipefail
sudo apt-get update -qq
sudo apt-get install -y -qq socat conntrack ipset kmod
sudo swapoff -a
sudo mkdir -p /etc/cni/net.d /opt/cni/bin /var/lib/kubelet /var/lib/kube-proxy /var/lib/kubernetes /var/run/kubernetes
chmod +x kubelet kube-proxy containerd containerd-shim-runc-v2 containerd-stress runc crictl
sudo mv kubelet kube-proxy runc crictl /usr/local/bin/
sudo mv containerd containerd-shim-runc-v2 containerd-stress /bin/
sudo mv cni-plugins/* /opt/cni/bin/
sudo mv 99-loopback.conf /etc/cni/net.d/
sudo modprobe br-netfilter
grep -qxF "br-netfilter" /etc/modules-load.d/modules.conf 2>/dev/null || echo "br-netfilter" | sudo tee -a /etc/modules-load.d/modules.conf
grep -qxF "net.bridge.bridge-nf-call-iptables = 1" /etc/sysctl.d/kubernetes.conf 2>/dev/null || echo "net.bridge.bridge-nf-call-iptables = 1" | sudo tee -a /etc/sysctl.d/kubernetes.conf
grep -qxF "net.bridge.bridge-nf-call-ip6tables = 1" /etc/sysctl.d/kubernetes.conf 2>/dev/null || echo "net.bridge.bridge-nf-call-ip6tables = 1" | sudo tee -a /etc/sysctl.d/kubernetes.conf
sudo sysctl -p /etc/sysctl.d/kubernetes.conf
sudo mkdir -p /etc/containerd
sudo mv containerd-config.toml /etc/containerd/config.toml
sudo mv kubelet-config.yaml /var/lib/kubelet/
sudo mv kube-proxy-config.yaml /var/lib/kube-proxy/
sudo mv containerd.service kubelet.service kube-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable containerd kubelet kube-proxy
sudo systemctl restart containerd kubelet kube-proxy
REMOTE

echo "Verifying worker ${WORKER_IP}"
ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${WORKER_IP}" \
  "systemctl is-active containerd kubelet kube-proxy"
