# Deployment notes

## EC2/EBS data volume

Mount the attached EBS volume on the host and point Compose at it:

```env
BABELFISH_DATA_PATH=/mnt/babelfish-data
DATABASE=babelfish_db
MIGRATION_MODE=multi-db
TSQL_DATABASE=scoringdb
```

The container stores PostgreSQL/Babelfish data at `/var/lib/babelfish/data`.

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
