# Adding a site

1. Install the site with `siteId` empty. The site agent restarts until step 2.
2. Register it:
   ```bash
   NICO_TOKEN=<jwt> scripts/register-site.sh --global-context <global> --site-context <site> \
     --name <site> --rest-url http://localhost:8388 \
     --creds-url https://site-manager.example.com:8100/v1/sitecreds
   ```
   The token must be a `PROVIDER_ADMIN` token REST accepts. Add an issuer for your operators in the global `nico-rest.yaml` override. Reach REST with `kubectl -n nico-rest port-forward svc/nico-rest-api 8388`.
3. Put the printed site ID in the site's `settings.yaml`.
4. Add the site to the global `nico-provider.yaml` override, with its node types. Instance type IDs come from `GET /v2/org/<org>/nico/instance/type?siteId=<id>`.

Removing a node type deletes its claims. Only remove one nobody uses.
