#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE="${1:-${BABELFISH_IMAGE:-ttl.sh/ocker-babelfishpg-babelfish-scoring-db:15m}}"

if [ ! -f .env ]; then
  echo "Creating .env from .env.example"
  cp .env.example .env
fi

if grep -q '^BABELFISH_IMAGE=' .env; then
  sed -i "s|^BABELFISH_IMAGE=.*|BABELFISH_IMAGE=$IMAGE|" .env
else
  printf '\nBABELFISH_IMAGE=%s\n' "$IMAGE" >> .env
fi

echo "Using image: $IMAGE"
echo "Updated .env:"
grep '^BABELFISH_IMAGE=' .env

echo "Pulling image with Docker Compose"
docker compose pull babelfish

echo "Starting Babelfish without building on this server"
docker compose up -d --no-build babelfish

docker compose ps
