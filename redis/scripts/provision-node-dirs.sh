#!/usr/bin/env bash
set -euo pipefail

# Provision Redis data directory on mgplcb05
NODE="192.168.29.147"
SSH_KEY="$HOME/.ssh/id_rsa_devops_ssh"
DATA_DIR="/opt/k8s-pers/vol1/redis-pc-ng"

echo "=== Provisioning Redis directory on mgplcb05 ==="
echo "Node: $NODE"
echo "Dir:  $DATA_DIR"
echo ""

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$NODE" << EOF
  mkdir -p $DATA_DIR
  chmod 775 $DATA_DIR
  # Redis runs as UID 1001 in Bitnami image
  chown 1001:1001 $DATA_DIR
  ls -la $DATA_DIR
  echo "Directory provisioned."
EOF
