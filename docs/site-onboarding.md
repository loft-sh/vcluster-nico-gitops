# Adding a site

1. Install the site with `siteId` empty. The site agent restarts until step 2.
2. Register it, with a token the Platform signs:
   ```bash
   kubectl --context <global> -n nico-rest port-forward svc/nico-rest-api 8388
   ```
   ```bash
   NICO_TOKEN=$(scripts/platform-token.sh --context <global> --platform-host platform.example.com --org <nicoOrg>) \
   scripts/register-site.sh --global-context <global> --site-context <site> --org <nicoOrg> \
     --name <site> --rest-url http://localhost:8388 \
     --creds-url https://site-manager.example.com:8100/v1/sitecreds
   ```
3. Put the printed site ID in the site's `settings.yaml`.
4. Connect the site cluster to the Platform. The site's Platform agent restarts until you do.
   ```bash
   scripts/connect-site.sh --global-context <global> --site-context <site> --name <site>
   ```
5. Add the site to the global `nico-provider.yaml` override, with its node types. Instance type IDs come from `GET /v2/org/<org>/nico/instance/type?siteId=<id>`.
6. Optional: register its machines from NetBox. See [netbox.md](netbox.md).

Don't add a second issuer for the provider org in `nico-rest.yaml`. That reserves the org name and the Platform can no longer use it.

Removing a node type deletes its claims. Only remove one nobody uses.
