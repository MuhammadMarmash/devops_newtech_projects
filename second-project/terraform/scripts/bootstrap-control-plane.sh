#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_IP:?SERVER_IP must be set}"

cd "$HOME"

if [[ ! -f downloads/kube-apiserver ]]; then
  mkdir -p downloads
  wget -q --https-only --timestamping -P downloads -i downloads-amd64.txt
  tar -xzf downloads/etcd-v3.6.0-rc.3-linux-amd64.tar.gz -C downloads
  mv downloads/etcd-v3.6.0-rc.3-linux-amd64/etcd downloads/etcd-v3.6.0-rc.3-linux-amd64/etcdctl downloads/
  chmod +x downloads/kube-apiserver downloads/kube-controller-manager downloads/kube-scheduler downloads/kubectl downloads/etcd downloads/etcdctl
fi

if [[ -f encryption-key.b64 ]]; then
  echo "encryption-key.b64 already exists on this jumpbox — reusing it, regenerating it would make every already-encrypted Secret unreadable"
else
  head -c 32 /dev/urandom | base64 >encryption-key.b64
fi
ENCRYPTION_KEY="$(cat encryption-key.b64)" envsubst <encryption-config.yaml.template >encryption-config.yaml

ALREADY_BOOTSTRAPPED="$(ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${SERVER_IP}" \
  'systemctl is-active --quiet kube-apiserver && echo yes || echo no')"

if [[ "${ALREADY_BOOTSTRAPPED}" == "yes" ]]; then
  echo "kube-apiserver is already active on server — skipping control plane bootstrap"
  exit 0
fi

scp -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no \
  downloads/etcd downloads/etcdctl downloads/kube-apiserver downloads/kube-controller-manager downloads/kube-scheduler downloads/kubectl \
  etcd.service kube-apiserver.service kube-controller-manager.service kube-scheduler.service \
  kube-scheduler.yaml kube-apiserver-to-kubelet.yaml \
  certs/ca.crt certs/ca.key certs/kube-api-server.crt certs/kube-api-server.key certs/service-accounts.crt certs/service-accounts.key \
  encryption-config.yaml \
  "admin@${SERVER_IP}:~/"

ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${SERVER_IP}" bash -s <<'REMOTE'
set -euo pipefail
sudo mv etcd etcdctl kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
sudo mkdir -p /etc/etcd /var/lib/etcd /var/lib/kubernetes /etc/kubernetes/config
sudo chmod 700 /var/lib/etcd
sudo cp ca.crt kube-api-server.key kube-api-server.crt /etc/etcd/
sudo mv ca.crt ca.key kube-api-server.key kube-api-server.crt service-accounts.key service-accounts.crt encryption-config.yaml /var/lib/kubernetes/
sudo mv kube-controller-manager.kubeconfig kube-scheduler.kubeconfig /var/lib/kubernetes/
sudo mv kube-scheduler.yaml /etc/kubernetes/config/
sudo mv etcd.service kube-apiserver.service kube-controller-manager.service kube-scheduler.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable etcd kube-apiserver kube-controller-manager kube-scheduler
sudo systemctl start etcd kube-apiserver kube-controller-manager kube-scheduler
sleep 10
kubectl apply -f kube-apiserver-to-kubelet.yaml --kubeconfig admin.kubeconfig
REMOTE

echo "Verifying control plane"
ssh -i "$HOME/kthw.pem" -o StrictHostKeyChecking=no "admin@${SERVER_IP}" \
  "kubectl cluster-info --kubeconfig admin.kubeconfig"
