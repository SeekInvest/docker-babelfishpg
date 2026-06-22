# Deployment notes

## EC2/EBS data volume

Mount the attached EBS volume on the host and point Compose at a subdirectory under it:

```env
BABELFISH_DATA_PATH=/mnt/babelfish-data/pgdata
DATABASE=babelfish_db
MIGRATION_MODE=multi-db
TSQL_DATABASE=scoringdb
```

The container stores PostgreSQL/Babelfish data at `/var/lib/babelfish/data`.

Use a subdirectory like `/mnt/babelfish-data/pgdata`, not the mount root `/mnt/babelfish-data`, because ext4 creates `lost+found` at the mount root and PostgreSQL `initdb` requires an empty data directory.

The host data directory must be writable by the container's `postgres` user. Check the actual UID/GID from the image:

```bash
docker compose run --rm --no-deps --entrypoint sh babelfish -c 'id -u; id -g'
```

Then set ownership with numeric IDs. Example if the image prints `1001` and `1001`:

```bash
sudo mkdir -p /mnt/babelfish-data/pgdata
sudo chown 1001:1001 /mnt/babelfish-data/pgdata
sudo chmod 700 /mnt/babelfish-data/pgdata
```

If using GNU `install`, numeric IDs need `#` prefixes:

```bash
sudo install -d -m 700 -o '#1001' -g '#1001' /mnt/babelfish-data/pgdata
```

If Docker was installed as a Snap package, bind mounts under `/mnt` may need Snap removable-media access:

```bash
snap list docker || true
sudo snap connect docker:removable-media || true
sudo snap restart docker || true
```

## T-SQL database and users

On startup, `start.sh` now idempotently creates the application-visible T-SQL database from `TSQL_DATABASE` and the compatibility users from these env vars:

```env
OLD_Scoring_API_MSSQL_USERNAME=...
OLD_Scoring_API_MSSQL_PASSWORD=...
OLD_FINHUB_ETL_MSSQL_USERNAME=...
OLD_FINHUB_ETL_MSSQL_PASSWORD=...
```

Access granted:

- `OLD_Scoring_API_MSSQL_USERNAME`: `db_datareader`
- `OLD_FINHUB_ETL_MSSQL_USERNAME`: `db_datareader` + `db_datawriter`

## AWS DMS target notes

For a Babelfish target in `multi-db` mode:

- Target engine: Amazon Aurora PostgreSQL/PostgreSQL-compatible endpoint
- Database: `babelfish_db`
- Endpoint settings:
  - `DatabaseMode=Babelfish`
  - `BabelfishDatabaseName=scoringdb`
- Target table preparation: `Do nothing` or `Truncate`; do not use drop/recreate.
- Use the mapping in `dms/table-mappings-scoringdb.json` as a starting point.

## Snapshots

Use AWS Data Lifecycle Manager or AWS Backup for the EBS volume. For the safest EBS snapshot:

```bash
docker compose stop babelfish
# create EBS snapshot of the attached data volume
docker compose up -d babelfish
```

For production-grade recovery, also plan PostgreSQL-native backups/WAL archiving.
