# Deploying to production

Runs [iobio-gru-backend][release] 2.0.0 behind Caddy on a single EC2 instance as
a one-node Docker Swarm. Swarm restarts the container on crash and on reboot,
and rolls out updates without dropping the site. Caddy terminates HTTPS with
automatic Let's Encrypt certificates.

[release]: https://github.com/iobio/iobio-gru-backend/tree/release-2.0.0

## Files

| File | Purpose |
| --- | --- |
| `docker-stack.yml` | The two services: `gene` (backend + frontend) and `caddy` |
| `Caddyfile` | TLS and reverse proxy |
| `production.env` | Where and how it's hosted. Sourced by `deploy.sh` |
| `iobio.env` | What the app shows. Passed to the container verbatim |
| `deploy.sh` | Validates config, then `docker stack deploy` |

Both env files are gitignored and live only on the server; copy them from the
`.example` versions.

## 1. Launch the instance

- **AMI:** Ubuntu 24.04 LTS (x86_64)
- **Instance type:** `t3a.medium` (2 vCPU / 4 GB). The backend shells out to
  samtools, bcftools, VEP and freebayes, so analyses are CPU- and memory-hungry.
  `t3a` is burstable: under sustained load watch the CPU credit balance, and
  watch memory during VEP-heavy requests. Resize if either runs short.
- **Root volume:** 30 GB gp3. Holds the image (several GB — it bundles VEP and
  the rest of the tool chain) plus per-request temp files, which can be large
  during variant annotation.
- **Data volume:** a separate 150 GB gp3 volume for the gru data directory
  (~128 GB today). EBS volumes can be grown in place if a later data version
  outgrows it.

## 2. Networking and DNS

- Allocate an Elastic IP and associate it with the instance.
- Security group inbound: `80/tcp` and `443/tcp` (plus `443/udp` for HTTP/3)
  from `0.0.0.0/0`; `22/tcp` from your office/VPN range only.
- Create an A record for `gene.example.org` pointing at the Elastic IP.

**DNS must resolve before the first deploy.** Caddy issues the certificate via
an HTTP challenge on port 80, which fails if the name doesn't point here yet.

## 3. Mount the data volume

```bash
lsblk                                   # identify the volume, e.g. nvme1n1
sudo mkfs.ext4 -m 0 /dev/nvme1n1        # first time only — destroys data
sudo mkdir -p /mnt/gru_data
echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1) /mnt/gru_data ext4 defaults,nofail 0 2" \
  | sudo tee -a /etc/fstab
sudo mount -a
```

Use the UUID rather than the device name — NVMe names can change across reboots.

## 4. Download the data directory

The backend requires data directory **version 1.15.0 or newer** and exits at
startup if it's older. Version 2.0.0 matches this image:

```bash
curl https://rclone.org/install.sh | sudo bash
sudo chown ubuntu:ubuntu /mnt/gru_data
rclone sync --progress --http-url https://files.iobio.io \
  :http:gru_data/data/gru_data_2.0.0/ \
  /mnt/gru_data
cat /mnt/gru_data/VERSION
```

This is a ~128 GB transfer and takes hours — run it under `tmux` or `screen` so
an SSH drop doesn't kill it. Rerunning the same command later syncs an existing
copy instead of downloading everything again, which is also how you upgrade
versions.

## 5. Install Docker and initialize Swarm

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu        # log out and back in
sudo systemctl enable --now docker    # ensures the stack returns after reboot
docker swarm init
```

## 6. Deploy

```bash
git clone <this repo> ~/iobio-apps
cd ~/iobio-apps
cp production.env.example production.env
cp iobio.env.example iobio.env
$EDITOR production.env                # set ACME_EMAIL; confirm DOMAIN, DATA_DIR
$EDITOR iobio.env                     # optional: site text, OMIM key
./deploy.sh
```

First start pulls the image and then reads the data directory indexes, so allow
a few minutes before the site answers.

## Verify

```bash
docker stack services gene                     # 1/1 replicas for both
curl -sI https://gene.example.org | head -1    # 200, valid certificate
curl -s https://gene.example.org/config.json   # effective app config
curl -s https://gene.example.org/api           # backend status JSON
```

`/config.json` is the fastest way to confirm `iobio.env` took effect — it
returns the config the frontend actually sees, including `site_name`, the intro
paragraphs and `backend.origin`.

Then load the site in a browser and search a gene (e.g. `BRCA2`) to exercise the
streaming analysis path end to end.

To confirm resilience: `docker kill $(docker ps -q -f name=gene_gene)` and watch
Swarm replace the task within seconds.

## Route layout

The backend mounts routes by path prefix, most specific first, and returns 404
for anything unmatched. With the shipped `iobio.env`:

| Path | Serves |
| --- | --- |
| `/api` | Backend API and status JSON |
| `/bam` | bam.iobio app (image default) |
| `/` | gene app, including `/config.json` |

Upstream's default puts the gene app at `/gene` and the backend at `/`, which
would make the root of this domain a 404. `IOBIO_GENE_PATH_PREFIX=/` in
`iobio.env` moves the app to the root, matching what `gene.example.org` implies.

The container healthcheck requests `/`, which works while either the gene app or
the backend is mounted there. If you ever give both a non-root prefix, update the
`healthcheck` in `docker-stack.yml` to match.

The backend rebuilds request URLs from `X-Forwarded-Proto` and
`X-Forwarded-Host`, both of which Caddy sets by default.

## Operations

```bash
docker stack services gene              # replica counts, image versions
docker stack ps gene --no-trunc         # task history, failure reasons
docker service logs -f gene_gene        # backend request log
docker service logs -f gene_caddy       # TLS / access log
```

**Deploy a new backend version:** bump `IMAGE` in `production.env`, then
`./deploy.sh`. The backend updates `start-first`, so the new container must pass
its healthcheck before the old one retires.

**Change app config:** edit `iobio.env`, then `./deploy.sh`.

**Change the Caddyfile:** edit it, then `docker service update --force gene_caddy`.
Caddy is the one service with brief downtime on update, because only one task can
bind port 443.

**Roll back:** `docker service rollback gene_gene`

**Certificates** live in the `gene_caddy_data` volume and renew automatically.
Don't delete that volume casually — Let's Encrypt rate-limits reissuance.

**Logs** are capped at 5 × 50 MB per service by Docker's json-file driver, so
they can't fill the root volume. Nothing is shipped off-box: if the instance is
lost, its logs are lost with it.
