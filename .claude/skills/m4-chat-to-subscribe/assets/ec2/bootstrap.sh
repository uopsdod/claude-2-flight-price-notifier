#!/bin/bash
# M4 step 4a: run once as root on the fresh Ubuntu 24.04 instance (via SSM Run Command).
# Installs Node 24, OpenClaw, the AWS CLI, and a 2 GB swap file. Safe to re-run.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl python3
if ! node -v 2>/dev/null | grep -q '^v24'; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
fi
# npm 11+ skips dependency install scripts unless allowed; OpenClaw needs them (bundled plugins, native modules).
(cd /tmp && npm install -g --allow-scripts=@google/genai,esbuild,koffi,protobufjs,openclaw openclaw@latest)
command -v aws >/dev/null || snap install aws-cli --classic
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
install -d -o ubuntu -g ubuntu -m 700 /home/ubuntu/.openclaw
echo "node $(node -v) | openclaw $(openclaw --version) | $(aws --version 2>&1 | cut -d' ' -f1)"
