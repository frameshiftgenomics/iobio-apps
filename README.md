# iobio-apps

Deployment config for a self-hosted [iobio][iobio] gene analysis app: one
[`iobio-gru-backend`][release] container serving both the API and the bundled
frontend, behind Caddy on a single host.

[iobio]: https://iobio.io
[release]: https://github.com/iobio/iobio-gru-backend/tree/release-2.0.0

| File | Purpose |
| --- | --- |
| `docker-stack.yml`, `Caddyfile` | The stack: backend plus HTTPS reverse proxy |
| `deploy.sh` | Syncs the data directory, then deploys or updates the stack |
| `production.env.example` | Host settings — domain, ACME email, data path and source, image tag |
| `iobio.env.example` | App settings — route prefixes, site name, intro text, flags |
| [`DEPLOYMENT.md`](DEPLOYMENT.md) | Provisioning and operations |

The backend needs the ~128 GB gru data directory on the host, and exits at
startup without one. `deploy.sh` syncs it from `DATA_URL` with rclone before each
deploy, so the data tracks the current 2.x release; pass `--no-sync` to skip
that.

```bash
cp production.env.example production.env
cp iobio.env.example iobio.env
# fill both in, then
./deploy.sh
```

`deploy.sh` is idempotent — first deploys, data syncs, config changes and version
bumps. Both real env files are gitignored and live only on the server. App
settings are environment variables merged over the backend's `config.json` and
served at `/config.json`.

Read [DEPLOYMENT.md](DEPLOYMENT.md) before the first deploy: DNS has to resolve
to the instance or certificate issuance fails.
