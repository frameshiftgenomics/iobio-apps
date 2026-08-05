# Deploying to production

[iobio-gru-backend][release] 2.0.0 behind Caddy as a one-node Docker Swarm on a
single EC2 instance: restarts on crash and reboot, rolling updates, automatic
Let's Encrypt certificates.

[release]: https://github.com/iobio/iobio-gru-backend/tree/release-2.0.0

## 1. Instance

- Ubuntu 24.04 LTS (x86_64), `t3a.medium` — burstable, so watch CPU credits and
  memory under load
- Root volume 30 GB gp3
- Data volume 150 GB gp3, **same Availability Zone as the instance** — EBS can't
  attach across AZs

## 2. Networking

- Elastic IP associated with the instance
- Inbound: `80/tcp`, `443/tcp`, `443/udp` from anywhere; `22/tcp` restricted
- A record `gene.example.org` → the Elastic IP, **resolving before the first
  deploy** or Caddy's certificate challenge fails

## 3. Mount the data volume

Create and attach the volume in the console (**Elastic Block Store → Volumes**),
then:

```bash
lsblk                              # find the device; usually nvme1n1
sudo mkfs.ext4 -m 0 /dev/nvme1n1   # erases it; -m 0 skips the 5% root reserve
sudo mkdir -p /mnt/gru_data        # create the mount point
# UUID survives device renames; nofail keeps a missing volume from blocking boot
echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1) /mnt/gru_data ext4 defaults,nofail 0 2" \
  | sudo tee -a /etc/fstab
sudo mount -a                      # mount now, and validate the fstab line
```

## 4. Data directory

Needs version **1.15.0 or newer**; 2.0.0 matches this image. ~128 GB and hours,
so run the sync inside `screen`. Rerunning syncs in place, which is also how you
upgrade.

```bash
sudo apt-get install -y screen
curl https://rclone.org/install.sh | sudo bash
sudo chown ubuntu:ubuntu /mnt/gru_data
screen
rclone sync --progress --exclude 'lost+found/**' --http-url https://files.iobio.io \
  :http:gru_data/data/gru_data_2.0.0/ /mnt/gru_data
```

## 5. Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu        # log out and back in
sudo systemctl enable --now docker    # stack returns after reboot
docker swarm init
```

## 6. Deploy

```bash
git clone <this repo> ~/iobio-apps && cd ~/iobio-apps
cp production.env.example production.env   # set ACME_EMAIL, DOMAIN, DATA_DIR
cp iobio.env.example iobio.env             # site text, OMIM key
./deploy.sh
```

Allow a few minutes on first start for the image pull and data indexing.

```bash
docker stack services gene                     # 1/1 replicas for both
curl -sI https://gene.example.org | head -1    # 200, valid certificate
curl -s https://gene.example.org/config.json   # effective app config
```

Then search a gene (e.g. `BRCA2`) in a browser to exercise the streaming path.

## Notes

Routes mount by path prefix, most specific first, 404 otherwise: `/api` backend,
`/bam` bam.iobio, `/` gene app. `IOBIO_GENE_PATH_PREFIX=/` overrides the upstream
default of `/gene`, which would 404 at the root; the healthcheck requests `/`, so
keep something mounted there.

```bash
docker stack ps gene --no-trunc             # task history, failure reasons
docker service logs -f gene_gene            # backend request log
docker service rollback gene_gene           # undo a bad update
docker service update --force gene_caddy    # reload the Caddyfile
```

- New version: bump `IMAGE` in `production.env`, `./deploy.sh`. Updates are
  `start-first`, so the new container must pass its healthcheck first
- Config change: edit `iobio.env`, `./deploy.sh`
- Certs live in the `gene_caddy_data` volume — don't delete it, Let's Encrypt
  rate-limits reissuance
- Logs capped at 5 × 50 MB per service; nothing is shipped off-box
