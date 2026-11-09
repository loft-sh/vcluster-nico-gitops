# In-cluster Vault

For sites without their own Vault. The `site-vault` layer runs Vault in the site cluster and sets it up for NICo.

## Use it

1. Add the layer before `site-base`. With Flux:
   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: nico-site-vault
     namespace: flux-system
   spec:
     interval: 10m
     path: ./patterns/flux/site-vault
     prune: true
     wait: true
     timeout: 30m
     sourceRef:
       kind: GitRepository
       name: vcluster-nico-gitops
   ```
   Then add `dependsOn: [{name: nico-site-vault}]` to `nico-site-base`. With Argo CD, add a root Application for `patterns/argocd/site-vault`.
2. Set `vaultAddr` to `http://vault.vault.svc.cluster.local:8200`.
3. Run `bootstrap-site-secrets.sh` without `NICO_VAULT_TOKEN`. The layer creates `nico-system/nico-vault-token`.
4. Vault runs 3 pods, one per node. With fewer nodes, set `server.affinity: ""` in `overrides/vault.yaml`.

## How it unseals

Vault starts locked after every restart. The `vault-unseal` pod initializes Vault once and keeps the unseal key and root token in the `vault/vault-unseal-keys` Secret. It unseals any Vault pod that starts locked, so Vault comes back on its own.

## This is a stop-gap

Anyone who can read `vault-unseal-keys` can open Vault and every secret in it. Before production, secure it:

- Use auto-unseal with your cloud KMS or another Vault's Transit engine, or point the site at a Vault you run. Then remove this layer and the Secret.
- Or unseal by hand after a full restart and keep the key offline.
- Limit who can read Secrets in the `vault` namespace.
- Vault listens without TLS inside the cluster. Add TLS.

## Kubernetes auth

NICo logs in to Vault with Kubernetes auth only on the mount `kubernetes`. Mount it there, or use the experimental build, which reads another mount from `VAULT_KUBERNETES_AUTH_MOUNT`. See [experimental.md](experimental.md).
