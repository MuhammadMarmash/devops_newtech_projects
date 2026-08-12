#!/usr/bin/env bash
set -euo pipefail

cd "$HOME"

if [[ -f downloads/worker/kubelet ]]; then
  echo "downloads/worker/kubelet already exists on this jumpbox — skipping worker binary preparation"
  exit 0
fi

mkdir -p downloads/worker downloads/cni-plugins
tar -xzf downloads/crictl-v1.32.0-linux-amd64.tar.gz -C downloads/worker
tar -xzf downloads/containerd-2.1.0-beta.0-linux-amd64.tar.gz --strip-components 1 -C downloads/worker
tar -xzf downloads/cni-plugins-linux-amd64-v1.6.2.tgz -C downloads/cni-plugins
cp downloads/kubelet downloads/kube-proxy downloads/worker/
mv downloads/runc.amd64 downloads/worker/runc
chmod +x downloads/worker/* downloads/cni-plugins/*
