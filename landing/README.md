# standalone Cloudflare Pages site

Static site, unrelated to the docker-compose stack in this repo. Deployed via Cloudflare's `wrangler` CLI, not through any workflow or script here — run manually from this directory:

```bash
npx wrangler pages deploy landing --project-name=<CLOUDFLARE_PAGES_PROJECT>
```

Account is picked up from your `wrangler login` session — no need to pass it explicitly.
