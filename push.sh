#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCAL_IMAGE="${LOCAL_IMAGE:-ocker-babelfishpg-babelfish-scoring-db:local}"
TTL_IMAGE="${TTL_IMAGE:-ttl.sh/ocker-babelfishpg-babelfish-scoring-db:15m}"

echo "Building local image: $LOCAL_IMAGE"
docker build -t "$LOCAL_IMAGE" .

echo "Tagging ttl.sh image: $TTL_IMAGE"
docker tag "$LOCAL_IMAGE" "$TTL_IMAGE"

echo "Pushing ttl.sh image: $TTL_IMAGE"
docker push "$TTL_IMAGE"

cat <<EOF

Pushed image:
$TTL_IMAGE

Put this in the server .env:
BABELFISH_IMAGE=$TTL_IMAGE

Or run this on the server from the repo directory:
./pull.sh "$TTL_IMAGE"

Reminder: ttl.sh image tag :15m expires quickly, so pull it on the server right away.
EOF
