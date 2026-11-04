#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: NICO_VAULT_TOKEN=<token> scripts/bootstrap-site-secrets.sh --context <kube-context> [--dpu]

Creates the namespaces and Secrets a NICo site expects. Existing Secrets are left
unchanged, except nico-vault-token, which is replaced when NICO_VAULT_TOKEN is set.

  --dpu              also create the secrets the DPU management layer (site-dpu) needs
  NICO_VAULT_TOKEN   Vault token for nico-api, with read/write on the NICo KV mount and
                     issue/sign on the NICo PKI role (see docs/prerequisites.md)
EOF
  exit 2
}

CONTEXT=""
DPU=false
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT=$2; shift 2 ;;
    --dpu) DPU=true; shift ;;
    *) usage ;;
  esac
done
[ -n "$CONTEXT" ] || usage

k() { kubectl --context "$CONTEXT" "$@"; }
rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }
exists() { k -n "$1" get secret "$2" >/dev/null 2>&1; }

for ns in nico-system nico-rest cert-manager; do
  k get namespace "$ns" >/dev/null 2>&1 || k create namespace "$ns" >/dev/null
done

if exists nico-system nico-postgres-credentials; then
  echo "nico-system/nico-postgres-credentials exists, keeping it"
  APP_PW=$(k -n nico-system get secret nico-postgres-credentials -o jsonpath='{.data.app_password}' | base64 -d)
else
  APP_PW=$(rand)
  k -n nico-system create secret generic nico-postgres-credentials \
    --from-literal=admin_password="$(rand)" --from-literal=app_password="$APP_PW" >/dev/null
  echo "created nico-system/nico-postgres-credentials"
fi

DB_SECRET=nico-system.nico.nico-pg-cluster.credentials
if ! exists nico-system "$DB_SECRET"; then
  HOST=nico-postgres.nico-system.svc.cluster.local
  k -n nico-system create secret generic "$DB_SECRET" \
    --from-literal=username=nico --from-literal=password="$APP_PW" \
    --from-literal=host="$HOST" --from-literal=port=5432 --from-literal=dbname=nico \
    --from-literal=uri="postgres://nico:${APP_PW}@${HOST}:5432/nico?sslmode=disable" >/dev/null
  echo "created nico-system/$DB_SECRET"
fi

if ! exists nico-system ssh-host-key; then
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C nico-ssh-console -f "$WORK/ssh_host_ed25519_key"
  k -n nico-system create secret generic ssh-host-key \
    --from-file=ssh_host_ed25519_key="$WORK/ssh_host_ed25519_key" \
    --from-file=ssh_host_ed25519_key.pub="$WORK/ssh_host_ed25519_key.pub" >/dev/null
  echo "created nico-system/ssh-host-key"
fi

if [ -n "${NICO_VAULT_TOKEN:-}" ]; then
  k -n nico-system create secret generic nico-vault-token --from-literal=token="$NICO_VAULT_TOKEN" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  echo "stored nico-system/nico-vault-token"
elif ! exists nico-system nico-vault-token; then
  echo "nico-system/nico-vault-token is missing: re-run with NICO_VAULT_TOKEN set before NICo starts" >&2
fi

if [ "$DPU" = true ]; then
  k get namespace dpf-operator-system >/dev/null 2>&1 || k create namespace dpf-operator-system >/dev/null
  if ! exists dpf-operator-system hbn-user-password; then
    k -n dpf-operator-system create secret generic hbn-user-password --from-literal=password="$(rand 10 | tr 'A-Z' 'a-z')" >/dev/null
    k -n dpf-operator-system label secret hbn-user-password dpu.nvidia.com/image-pull-secret="" >/dev/null
    echo "created dpf-operator-system/hbn-user-password"
  fi
fi
