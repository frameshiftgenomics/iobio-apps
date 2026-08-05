# iobio-apps

Deployment configuration for a self-hosted [iobio][iobio] gene analysis app. A
single [`iobio-gru-backend`][release] container serves both the API and the
bundled frontend, behind Caddy on one host.

[iobio]: https://iobio.io
[release]: https://github.com/iobio/iobio-gru-backend/tree/release-2.0.0

## Layout

| File | Purpose |
| --- | --- |
| `docker-stack.yml`, `Caddyfile` | The stack: backend plus HTTPS reverse proxy |
| `deploy.sh` | Deploys and updates the stack |
| `production.env.example` | Host settings — domain, ACME email, data path, image tag |
| `iobio.env.example` | App settings — route prefixes, site name, intro text, feature flags |
| [`DEPLOYMENT.md`](DEPLOYMENT.md) | Provisioning an instance, and day-to-day operations |

## The data directory

The backend needs a copy of the gru data directory on the host — roughly 128 GB
of reference and annotation files, version 1.15.0 or newer. It exits at startup
without one. See
[step 4 of DEPLOYMENT.md](DEPLOYMENT.md#4-download-the-data-directory) for the
`rclone` command.

## Deploying

It runs as a one-node Docker Swarm stack, which provides HTTPS with automatic
Let's Encrypt certificates, restarts on crash and on reboot, capped log files,
and rolling updates that wait for a healthcheck before retiring the old
container.

```bash
cp production.env.example production.env
cp iobio.env.example iobio.env
# fill both in, then
./deploy.sh
```

Application settings are environment variables read at startup. The backend
merges them over its built-in `config.json` and serves the result at
`/config.json`, which is the quickest way to check what the frontend sees.

`deploy.sh` is idempotent — the same command does first deploys, config changes
and version bumps. Both real env files are gitignored and live only on the
server. Read [DEPLOYMENT.md](DEPLOYMENT.md) before the first deploy: DNS has to
resolve to the instance beforehand or certificate issuance fails.
