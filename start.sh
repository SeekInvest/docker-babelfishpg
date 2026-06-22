#!/bin/sh
set -eu

BABELFISH_HOME=/opt/babelfish
BABELFISH_DATA=/var/lib/babelfish/data
INIT_MARKER=${BABELFISH_DATA}/.babelfish_initialized

cd ${BABELFISH_HOME}/bin

# Set default argument values
USERNAME=${USERNAME:-babelfish_user}
PASSWORD=${PASSWORD:-12345678}
DATABASE=${DATABASE:-babelfish_db}
MIGRATION_MODE=${MIGRATION_MODE:-single-db}
TSQL_DATABASE=${TSQL_DATABASE:-}
OLD_Scoring_API_MSSQL_USERNAME=${OLD_Scoring_API_MSSQL_USERNAME:-}
OLD_Scoring_API_MSSQL_PASSWORD=${OLD_Scoring_API_MSSQL_PASSWORD:-}
OLD_FINHUB_ETL_MSSQL_USERNAME=${OLD_FINHUB_ETL_MSSQL_USERNAME:-}
OLD_FINHUB_ETL_MSSQL_PASSWORD=${OLD_FINHUB_ETL_MSSQL_PASSWORD:-}

# Populate argument values from command
while getopts u:p:d:m: flag; do
	case "${flag}" in
		u) USERNAME=${OPTARG};;
		p) PASSWORD=${OPTARG};;
		d) DATABASE=${OPTARG};;
		m) MIGRATION_MODE=${OPTARG};;
	esac
done

# PostgreSQL folds unquoted identifiers to lowercase. Normalize these values so
# CREATE DATABASE and later connections use the same name (e.g. scoringDB -> scoringdb).
USERNAME=$(printf '%s' "${USERNAME}" | tr '[:upper:]' '[:lower:]')
DATABASE=$(printf '%s' "${DATABASE}" | tr '[:upper:]' '[:lower:]')
if [ -n "${TSQL_DATABASE}" ]; then
	TSQL_DATABASE=$(printf '%s' "${TSQL_DATABASE}" | tr '[:upper:]' '[:lower:]')
fi
PASSWORD_SQL=$(printf '%s' "${PASSWORD}" | sed "s/'/''/g")

sql_quote() {
	printf '%s' "$1" | sed "s/'/''/g"
}

tsql_ident() {
	printf '%s' "$1" | sed 's/]/]]/g'
}

postgres_started=0
start_temp_postgres() {
	if [ "${postgres_started}" -eq 0 ]; then
		./pg_ctl -D ${BABELFISH_DATA}/ -w start
		postgres_started=1
	fi
}

stop_temp_postgres() {
	if [ "${postgres_started}" -eq 1 ]; then
		./pg_ctl -D ${BABELFISH_DATA}/ -m fast -w stop
		postgres_started=0
	fi
}

run_tsql() {
	sql=$(cat)
	output=$(printf '%s\nGO\n' "${sql}" | tsql -H 127.0.0.1 -p 1433 -U "${USERNAME}" -P "${PASSWORD}" 2>&1 || true)
	if printf '%s' "${output}" | grep -Eiq '(^|[[:space:]])Msg [0-9]+|Unable to connect|Login failed|error'; then
		printf '%s\n' "${output}" >&2
		return 1
	fi
}

bootstrap_login_user() {
	login_name=$1
	login_password=$2
	access_mode=$3
	target_db=$4

	if [ -z "${login_name}" ]; then
		return 0
	fi
	if [ -z "${login_password}" ]; then
		echo "Password is required for login ${login_name}" >&2
		return 1
	fi

	login_name_sql=$(sql_quote "${login_name}")
	login_name_ident=$(tsql_ident "${login_name}")
	login_password_sql=$(sql_quote "${login_password}")
	target_db_ident=$(tsql_ident "${target_db}")

	if [ "${access_mode}" = "readwrite" ]; then
		extra_role="ALTER ROLE db_datawriter ADD MEMBER [${login_name_ident}]"
	else
		extra_role=""
	fi

	run_tsql <<- EOF
		USE [master]
		IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'${login_name_sql}')
		BEGIN
			CREATE LOGIN [${login_name_ident}] WITH PASSWORD = N'${login_password_sql}'
		END
		ELSE
		BEGIN
			ALTER LOGIN [${login_name_ident}] WITH PASSWORD = N'${login_password_sql}'
		END

		USE [${target_db_ident}]
		IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'${login_name_sql}')
		BEGIN
			CREATE USER [${login_name_ident}] FOR LOGIN [${login_name_ident}]
		END
		ALTER ROLE db_datareader ADD MEMBER [${login_name_ident}]
		${extra_role}
	EOF
}

bootstrap_tsql() {
	# In multi-db mode, create the application-visible SQL Server database name.
	# In single-db mode, the T-SQL database is the initialized Babelfish database.
	if [ "${MIGRATION_MODE}" = "multi-db" ]; then
		if [ -z "${TSQL_DATABASE}" ]; then
			echo "TSQL_DATABASE must be set when MIGRATION_MODE=multi-db" >&2
			return 1
		fi
		target_db=${TSQL_DATABASE}
		target_db_sql=$(sql_quote "${target_db}")
		target_db_ident=$(tsql_ident "${target_db}")

		run_tsql <<- EOF
			USE [master]
			IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'${target_db_sql}')
			BEGIN
				CREATE DATABASE [${target_db_ident}]
			END
		EOF
	else
		target_db=${DATABASE}
	fi

	bootstrap_login_user "${OLD_Scoring_API_MSSQL_USERNAME}" "${OLD_Scoring_API_MSSQL_PASSWORD}" readonly "${target_db}"
	bootstrap_login_user "${OLD_FINHUB_ETL_MSSQL_USERNAME}" "${OLD_FINHUB_ETL_MSSQL_PASSWORD}" readwrite "${target_db}"
}

# Initialize database cluster if it does not exist
if [ ! -f ${BABELFISH_DATA}/PG_VERSION ]; then
	./initdb -D ${BABELFISH_DATA}/ -E "UTF8"
	cat <<- EOF >> ${BABELFISH_DATA}/pg_hba.conf
		# Allow all connections
		host	all		all		0.0.0.0/0		md5
		host	all		all		::0/0				md5
	EOF
fi

# Configure Babelfish once per data directory. This also recovers data dirs that
# were partially initialized before this script completed successfully.
if [ ! -f ${INIT_MARKER} ]; then
	cat <<- EOF >> ${BABELFISH_DATA}/postgresql.conf
		#------------------------------------------------------------------------------
		# BABELFISH RELATED OPTIONS
		# These are going to step over previous duplicated variables.
		#------------------------------------------------------------------------------
		listen_addresses = '*'
		allow_system_table_mods = on
		shared_preload_libraries = 'babelfishpg_tds'
		babelfishpg_tds.listen_addresses = '*'
		babelfishpg_tsql.migration_mode = '${MIGRATION_MODE}'
	EOF

	start_temp_postgres

	# Set password for postgres
	./psql -v ON_ERROR_STOP=1 -d postgres \
		-c "ALTER USER postgres WITH PASSWORD '${PASSWORD_SQL}';"

	# Create or update Babelfish owner role
	./psql -v ON_ERROR_STOP=1 -d postgres \
		-c "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${USERNAME}') THEN CREATE USER ${USERNAME} WITH SUPERUSER CREATEDB CREATEROLE PASSWORD '${PASSWORD_SQL}' INHERIT; ELSE ALTER USER ${USERNAME} WITH SUPERUSER CREATEDB CREATEROLE PASSWORD '${PASSWORD_SQL}' INHERIT; END IF; END\$\$;"

	# Create Babelfish internal database if needed
	if ! ./psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${DATABASE}'" | grep -q 1; then
		./psql -v ON_ERROR_STOP=1 -d postgres \
			-c "CREATE DATABASE ${DATABASE} OWNER ${USERNAME};"
	fi

	./psql -v ON_ERROR_STOP=1 -d ${DATABASE} \
		-c "CREATE EXTENSION IF NOT EXISTS \"babelfishpg_tds\" CASCADE;" \
		-c "GRANT ALL ON SCHEMA sys to ${USERNAME};" \
		-c "ALTER USER ${USERNAME} CREATEDB;" \
		-c "ALTER SYSTEM SET babelfishpg_tsql.database_name = '${DATABASE}';" \
		-c "SELECT pg_reload_conf();"

	# After reloading to apply the migration_mode setting in postgresql.conf,
	# initialize a new connection.
	./psql -v ON_ERROR_STOP=1 -d ${DATABASE} \
		-c "CALL SYS.INITIALIZE_BABELFISH('${USERNAME}');"

	touch ${INIT_MARKER}
fi

# Create the app-visible T-SQL database and compatibility users. This is
# idempotent and runs on every start so changed passwords are applied.
if [ -n "${TSQL_DATABASE}" ] || [ -n "${OLD_Scoring_API_MSSQL_USERNAME}" ] || [ -n "${OLD_FINHUB_ETL_MSSQL_USERNAME}" ]; then
	start_temp_postgres
	bootstrap_tsql
fi

stop_temp_postgres

# Start postgres engine
exec ./postgres -D ${BABELFISH_DATA}/ -i
