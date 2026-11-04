#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/bootstrap-global-secrets.sh --context <kube-context> [--ca-cert <pem> --ca-key <pem>]

Creates the namespaces and Secrets the global control plane blueprint expects.
Existing Secrets are left unchanged, so the script is safe to re-run.

  --ca-cert, --ca-key   bring your own REST CA; otherwise a self-signed RSA 4096 CA is generated
  LICENSE_TOKEN         optional environment variable, stored as vcluster-platform-license
EOF
  exit 2
}

CONTEXT=""
CA_CERT=""
CA_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT=$2; shift 2 ;;
    --ca-cert) CA_CERT=$2; shift 2 ;;
    --ca-key) CA_KEY=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$CONTEXT" ] || usage

k() { kubectl --context "$CONTEXT" "$@"; }
rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }
exists() { k -n "$1" get secret "$2" >/dev/null 2>&1; }

for ns in nico-rest temporal cert-manager vcluster-platform; do
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
done

if exists nico-rest postgres-credentials; then
  echo "nico-rest/postgres-credentials exists, keeping it"
  REST_PW=$(k -n nico-rest get secret postgres-credentials -o jsonpath='{.data.nico_rest_password}' | base64 -d)
  TEMPORAL_PW=$(k -n nico-rest get secret postgres-credentials -o jsonpath='{.data.temporal_password}' | base64 -d)
else
  REST_PW=$(rand)
  TEMPORAL_PW=$(rand)
  k -n nico-rest create secret generic postgres-credentials \
    --from-literal=admin_password="$(rand)" \
    --from-literal=nico_rest_password="$REST_PW" \
    --from-literal=temporal_password="$TEMPORAL_PW" >/dev/null
  echo "created nico-rest/postgres-credentials"
fi

if ! exists nico-rest db-creds; then
  k -n nico-rest create secret generic db-creds --from-literal=username=nico_rest --from-literal=password="$REST_PW" >/dev/null
  echo "created nico-rest/db-creds"
fi
if ! exists temporal db-creds; then
  k -n temporal create secret generic db-creds --from-literal=username=temporal --from-literal=password="$TEMPORAL_PW" >/dev/null
  echo "created temporal/db-creds"
fi
if ! exists nico-rest temporal-encryption-key; then
  k -n nico-rest create secret generic temporal-encryption-key \
    --from-literal=temporal-encryption-key="$(openssl rand -base64 32)" >/dev/null
  echo "created nico-rest/temporal-encryption-key"
fi

if exists nico-rest ca-signing-secret; then
  echo "nico-rest/ca-signing-secret exists, keeping it"
else
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  if [ -n "$CA_CERT" ] && [ -n "$CA_KEY" ]; then
    cp "$CA_CERT" "$WORK/ca.crt"
    cp "$CA_KEY" "$WORK/ca.key"
  else
    openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
      -keyout "$WORK/ca.key" -out "$WORK/ca.crt" -subj "/CN=nico-rest-ca" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  fi
  for ns in nico-rest cert-manager; do
    k -n "$ns" create secret tls ca-signing-secret --cert="$WORK/ca.crt" --key="$WORK/ca.key" >/dev/null
    echo "created $ns/ca-signing-secret"
  done
fi

if ! exists vcluster-platform vcluster-platform-admin; then
  k -n vcluster-platform create secret generic vcluster-platform-admin --from-literal=password="$(rand 24)" >/dev/null
  echo "created vcluster-platform/vcluster-platform-admin (read it with: kubectl -n vcluster-platform get secret vcluster-platform-admin -o jsonpath='{.data.password}' | base64 -d)"
fi
if [ -n "${LICENSE_TOKEN:-}" ]; then
  k -n vcluster-platform create secret generic vcluster-platform-license --from-literal=token="$LICENSE_TOKEN" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  echo "stored vcluster-platform/vcluster-platform-license"
fi
