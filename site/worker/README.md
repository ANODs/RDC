# RDC's site worker

A Cloudflare Worker with one D1 database. It serves `rdc.timoshkin.dev`: every path is the
site as GitHub Pages publishes it (`tools/site.py` → the viewer at `/`, the landing page at
`/en/`, `/ru/`, `/zh/`), and `/api` is the landing page's backend:

- `POST /api/hit` — a page view or a download click;
- `GET /api/releases` — the latest release, its files and the download counts, from GitHub;
- `GET /api/stats` — what the page's statistics block draws.

It keeps counters per day and nothing per person: no addresses, no cookies. A visitor is told
apart for one day by a salted hash that is deleted the next night.

## Deploy

```sh
cd site/worker
npx wrangler d1 create rdc-site          # once; put the printed id into wrangler.toml
npx wrangler d1 execute rdc-site --remote --file schema.sql   # once
npx wrangler deploy
```

The domain in `wrangler.toml` must be a zone of the Cloudflare account. The page's address
and the worker's are in `site/site.json` (`base_url`, `worker_url`); with an empty
`worker_url` the page counts nothing, hides the statistics and reads releases from GitHub
itself.
