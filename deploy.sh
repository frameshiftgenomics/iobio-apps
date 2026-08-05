#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
export STACK_DIR="$PWD"

ENV_FILE="${ENV_FILE:-production.env}"

for f in "$ENV_FILE" iobio.env; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f not found (copy $f.example)" >&2
    exit 1
  fi
done

set -a
source "./$ENV_FILE"
set +a

for var in DOMAIN ACME_EMAIL DATA_DIR IMAGE; do
  if [[ -z "${!var:-}" ]]; then
    echo "error: $var is not set in $ENV_FILE" >&2
    exit 1
  fi
done

# A missing or unmounted data directory makes the backend exit on startup,
# which Swarm turns into a restart loop rather than an obvious error.
if [[ ! -f "$DATA_DIR/VERSION" ]]; then
  echo "error: $DATA_DIR/VERSION not found; is the data volume mounted?" >&2
  exit 1
fi

echo "Deploying $DOMAIN"
echo "  image: $IMAGE"
echo "  data:  $DATA_DIR (version $(cat "$DATA_DIR/VERSION"))"

docker stack deploy -c docker-stack.yml --prune gene

echo
docker stack services gene
