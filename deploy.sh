#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
export STACK_DIR="$PWD"

ENV_FILE="${ENV_FILE:-production.env}"

SYNC=1
case "${1:-}" in
  "") ;;
  --no-sync) SYNC=0 ;;
  *) echo "usage: $0 [--no-sync]" >&2; exit 1 ;;
esac

for f in "$ENV_FILE" iobio.env; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f not found (copy $f.example)" >&2
    exit 1
  fi
done

set -a
source "./$ENV_FILE"
set +a

for var in DOMAIN ACME_EMAIL DATA_DIR DATA_URL IMAGE; do
  if [[ -z "${!var:-}" ]]; then
    echo "error: $var is not set in $ENV_FILE" >&2
    exit 1
  fi
done

# The data volume is mounted with nofail, so a detached or unmounted volume
# leaves an empty directory on the root filesystem — which the sync below would
# happily fill with 128 GB.
if ! mountpoint -q "$DATA_DIR"; then
  echo "error: $DATA_DIR is not a mount point; is the data volume mounted?" >&2
  exit 1
fi

if ((SYNC)); then
  if ! command -v rclone >/dev/null; then
    echo "error: rclone not found (see DEPLOYMENT.md)" >&2
    exit 1
  fi
  echo "Syncing $DATA_URL"
  # DATA_URL is a versionless path that tracks the current data release, so
  # this also upgrades the data. The exclude is required: the remote lost+found
  # returns 403 and fails the whole run, and the local one must survive.
  rclone sync --progress --exclude 'lost+found/**' \
    --http-url "$DATA_URL" :http: "$DATA_DIR"
  echo
fi

# A missing or unmounted data directory makes the backend exit on startup,
# which Swarm turns into a restart loop rather than an obvious error.
if [[ ! -f "$DATA_DIR/VERSION" ]]; then
  echo "error: $DATA_DIR/VERSION not found; did the data sync run?" >&2
  exit 1
fi

echo "Deploying $DOMAIN"
echo "  image: $IMAGE"
echo "  data:  $DATA_DIR (version $(cat "$DATA_DIR/VERSION"))"

docker stack deploy -c docker-stack.yml --prune gene

echo
docker stack services gene
