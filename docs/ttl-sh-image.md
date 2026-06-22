# Using ttl.sh for a Temporary Prebuilt Image

Use this when the EC2 server is too small to build the Babelfish image locally.

`ttl.sh` hosts anonymous temporary Docker images. A tag like `:15m` expires after about 15 minutes, so build and push locally, then immediately pull on the server.

## Image names used

This repo uses a fixed, trackable local image name:

```text
ocker-babelfishpg-babelfish-scoring-db:local
```

For `ttl.sh`, the pushed temporary image is:

```text
ttl.sh/ocker-babelfishpg-babelfish-scoring-db:15m
```

No date/time suffix is used.

## 1. Build and push from your local machine

From the repo directory on your local machine:

```bash
./push.sh
```

`push.sh` builds the local image, tags it for `ttl.sh`, pushes it, and prints the exact value to put in the server `.env`:

```env
BABELFISH_IMAGE=ttl.sh/ocker-babelfishpg-babelfish-scoring-db:15m
```

You can override the defaults if needed:

```bash
LOCAL_IMAGE="ocker-babelfishpg-babelfish-scoring-db:local" \
TTL_IMAGE="ttl.sh/ocker-babelfishpg-babelfish-scoring-db:15m" \
./push.sh
```

## 2. Pull and run on the server

On the EC2 server, run this quickly before the `ttl.sh` image expires:

```bash
cd ~/docker-babelfishpg
./pull.sh "ttl.sh/ocker-babelfishpg-babelfish-scoring-db:15m"
```

`pull.sh` updates `.env`, runs `docker compose pull babelfish`, and starts Babelfish with:

```bash
docker compose up -d --no-build babelfish
```

`--no-build` is important. It prevents the EC2 server from attempting to build the image.

If no argument is passed, `pull.sh` defaults to:

```text
ttl.sh/ocker-babelfishpg-babelfish-scoring-db:15m
```

## Notes

- `ttl.sh` is temporary and public-by-link. Do not use it for long-term production image storage.
- If the image expires before the server pulls it, push a new tag and update `BABELFISH_IMAGE`.
- For a permanent setup, use Amazon ECR instead of `ttl.sh`.
