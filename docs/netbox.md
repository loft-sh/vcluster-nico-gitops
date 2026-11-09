# Machines from NetBox

A site's NodeProvider can register its machines from NetBox. Each tagged NetBox device becomes a NICo expected machine, and NICo onboards it.

## Set it up

1. Create a NetBox connector in the Platform. It holds the NetBox URL and an API token.
2. Tag the devices to import. The default tag is `vcluster-nico-sync`.
3. Add `netBox` to the site's entry in the global `nico-provider.yaml` override:
   ```yaml
   sites:
     - name: nico-site-1
       siteId: 00000000-0000-0000-0000-000000000000
       netBox:
         secretRef:
           name: netbox
           namespace: vcluster-platform
         tag: vcluster-nico-sync
         sites: [site-1]
         locations: [hall-1]
         bmcCredentials:
           namespace: bmc-logins
           secretName: default-bmc
         fixedBmcAddress: true
         dpuInterfaces:
           bmc: dpu*-bmc
           os: dpu*-oob
   ```
   Only `secretRef` is required. `sites` and `locations` limit the import to those NetBox slugs.

## BMC logins

NICo needs each server's BMC login. The sync takes the first it finds:

1. The device's `bmc_username` and `bmc_password` custom fields.
2. The Secret named in the device's `bmc_secret` custom field.
3. The `bmcCredentials.secretName` Secret.

If the Secret named on the device is missing, the sync waits. It does not fall back to the default.

The Secrets live in `bmcCredentials.namespace`. The sync reads only Secrets with the label `netbox.vcluster.com/bmc-credentials: "true"` and the keys `username` and `password`. Keep the logins in your secret store and create the Secrets with External Secrets:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: default-bmc
  namespace: bmc-logins
spec:
  secretStoreRef:
    kind: SecretStore
    name: vault-bmc
  target:
    name: default-bmc
    template:
      metadata:
        labels:
          netbox.vcluster.com/bmc-credentials: "true"
  data:
    - secretKey: username
      remoteRef:
        key: bmc/default
        property: username
    - secretKey: password
      remoteRef:
        key: bmc/default
        property: password
```
Give the store a Vault role that can read only the BMC paths.

## One token per site

Give each site its own NetBox token and connector, limited to that site's devices. The token must also read tags and module types, which NetBox does not scope to a site.

## What the sync does

- It only adds machines. A device that leaves NetBox or loses its tag is marked out of sync on its Platform Machine. Removing the machine is a manual step in NICo.
- Removing `netBox` from a site stops the sync. It changes nothing in NICo.
- The NodeProvider's `NetBoxSynced` condition says why a pass was skipped.
- NetBox labels such as device type and role go on the Platform Machine, so node types can select by them, for example `netbox.vcluster.com/device-type`.
