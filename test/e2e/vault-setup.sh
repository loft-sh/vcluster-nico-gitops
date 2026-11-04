#!/usr/bin/env bash
set -euo pipefail

v() { kubectl -n vault exec deploy/vault -- env VAULT_TOKEN=root vault "$@"; }

v secrets enable -path=nico-kv kv-v2 >/dev/null
v secrets enable -path=nico-pki pki >/dev/null
v secrets tune -max-lease-ttl=87600h nico-pki >/dev/null
v write -field=certificate nico-pki/root/generate/internal common_name=nico-e2e-ca ttl=87600h >/dev/null
v write nico-pki/roles/nico-cluster allow_any_name=true enforce_hostnames=false allow_ip_sans=true \
  allowed_uri_sans="spiffe://*" require_cn=false use_csr_common_name=true use_csr_sans=true key_type=any max_ttl=8760h >/dev/null

v auth enable kubernetes >/dev/null
v write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null

kubectl -n vault exec -i deploy/vault -- env VAULT_TOKEN=root vault policy write cert-manager - >/dev/null <<'POLICY'
path "nico-pki/sign/nico-cluster" { capabilities = ["create", "update"] }
POLICY
v write auth/kubernetes/role/cert-manager bound_service_account_names=cert-manager-vault \
  bound_service_account_namespaces=cert-manager token_policies=cert-manager ttl=1h >/dev/null

kubectl -n vault exec -i deploy/vault -- env VAULT_TOKEN=root vault policy write nico-app - >/dev/null <<'POLICY'
path "nico-kv/data/machines/*"     { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
path "nico-kv/metadata/machines/*" { capabilities = ["read", "list", "delete"] }
path "nico-kv/data/nico/*"         { capabilities = ["read", "list"] }
path "nico-pki/sign/nico-cluster"  { capabilities = ["create", "update"] }
path "nico-pki/issue/nico-cluster" { capabilities = ["create", "update"] }
path "nico-pki/cert/ca"            { capabilities = ["read"] }
POLICY
v token create -orphan -policy=nico-app -period=768h -field=token
