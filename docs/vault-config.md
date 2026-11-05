# Vault config

The `vault-config` layer sets up an existing Vault for NICo, using the [Vault Config Operator](https://github.com/redhat-cop/vault-config-operator). Point it at a nearly blank Vault and it creates everything [prerequisites.md](prerequisites.md) asks for. Skip it if your Vault is already set up. The `site-vault` layer sets up its own Vault and doesn't need it.

## What it creates

Everything sits under `vaultPrefix`. Policies are named `<prefix>-<name>`, with `/` replaced by `-`.

| Where | What |
|---|---|
| `vaultKvMount` | KV v2 for NICo |
| `vaultPkiMount` | PKI, with a root CA and the `vaultPkiRole` role |
| `vaultCertManagerAuthMount` | roles `cert-manager`, `nico-api`, `nico-system`, and `dpf` if `vaultDpu` is on |
| `<prefix>/approle` | role `nico` for NICo's static token, if `vaultStaticToken` is on |
| `<prefix>/kubernetes-global` | the global cluster's login, with roles `nico-rest-db` and `temporal-db`, if `vaultGlobal` is on |

Database credentials go in the KV mount at `nico-system/db`, `nico-rest/db` and `temporal/db`. The `vault-secrets` service account in each namespace can read and write its own path. The layer doesn't write them. Your secrets tooling does.

The mounts and the CA stay in Vault if you remove the layer. Deleting them would lose the CA key.

## Use it

1. Set `vaultPrefix` and put the mounts under it, e.g. `nico/kv`, `nico/pki` and `nico/kubernetes`. See [settings.md](settings.md).
2. Add the layer next to `site-base`. It needs `site-base`'s cert-manager. With Flux:
   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: nico-vault-config
     namespace: flux-system
   spec:
     interval: 10m
     path: ./patterns/flux/vault-config
     prune: true
     wait: true
     timeout: 30m
     sourceRef:
       kind: GitRepository
       name: vcluster-nico-gitops
   ```
   With Argo CD, add a root Application for `patterns/argocd/vault-config`. The examples have both.
3. Once the operator is installed, run this once with a Vault admin token:
   ```bash
   VAULT_ADDR=https://vault.example.com VAULT_TOKEN=<admin token> scripts/bootstrap-vault-operator.sh --context <site> --prefix nico
   ```
   It enables Kubernetes auth at the auth mount, gives the operator a policy over the prefix only, and checks the operator can log in. The token isn't printed or stored. Pass `--kubernetes-host` if Vault reaches the API server at another address than your kubeconfig does.
4. Mint NICo's token:
   ```bash
   VAULT_ADDR=https://vault.example.com scripts/mint-nico-vault-token.sh --context <site> --prefix nico
   ```
   It logs in as the operator, so it needs no admin token. `--rotate` replaces the token.

`site-base` waits for Vault. If you take longer than an hour, reconcile `site-prereqs` again.

Vault checks every login with the cluster's TokenReview, as the service account that logs in. The layer gives the operator, `vault-secrets` and, without the static token, `nico-api` the `system:auth-delegator` role. `site-base` does the same for cert-manager.

## NICo's token

NICo's handover build logs in with Kubernetes auth only on a mount named `kubernetes`. On any other mount it needs the static token, so `vaultStaticToken` is on by default. The `nico-api` role is there for NICo builds that log in with Kubernetes auth.

## The global cluster

Turn on `vaultGlobal` and set `vaultGlobalKubernetesHost` to the global API server, as Vault reaches it. Put its CA in `overrides/vault-config.yaml`:

```yaml
global:
  kubernetesCaCert: |
    -----BEGIN CERTIFICATE-----
    ...
```

On the global cluster, give `vault-secrets` in `nico-rest` and `temporal` the `system:auth-delegator` role.

## HCP Vault

This layer doesn't support HCP Vault yet.

The operator has one way to log in: it sends a service account token and a role to `auth/<path>/login`. Vault's JWT auth takes the same request. So the operator can log in through a JWT mount that holds the cluster's signing keys, and HCP Vault doesn't need to reach the API server. CI checks this login.

What's missing:

- The layer creates Kubernetes auth roles, not JWT roles.
- It doesn't set a Vault namespace. HCP Vault uses `admin`.
- `bootstrap-vault-operator.sh` only sets up Kubernetes auth.
