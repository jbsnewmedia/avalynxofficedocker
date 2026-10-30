#!/usr/bin/env bash
#
# Creates the least-privilege database role for the ActiveSync (EAS) container.
#
# Executed by the postgres image via /docker-entrypoint-initdb.d - i.e. only
# once, when the data volume is initialised. The role only gets LOGIN here;
# the table privileges are granted by the office entrypoint after every
# migration run (the tables do not exist yet at this point).
set -euo pipefail

EAS_DB_USER="${EAS_DB_USER:-eas_user}"

if [ -z "${EAS_DB_PASSWORD:-}" ]; then
    echo "[avalynxoffice] EAS_DB_PASSWORD is not set, skipping creation of role ${EAS_DB_USER}." >&2
    exit 0
fi

if ! printf '%s' "${EAS_DB_USER}" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$'; then
    echo "[avalynxoffice] EAS_DB_USER must match ^[a-z_][a-z0-9_]*$ (got: ${EAS_DB_USER})." >&2
    exit 1
fi

echo "[avalynxoffice] Creating EAS database role ${EAS_DB_USER} ..."
# The password is passed as a psql variable (not interpolated into the SQL
# text) and quoted server-side; the role name was validated above.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v role="$EAS_DB_USER" -v pw="$EAS_DB_PASSWORD" <<'EOSQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOINHERIT NOCREATEDB NOCREATEROLE NOSUPERUSER', :'role', :'pw') AS stmt
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec
GRANT CONNECT ON DATABASE :"DBNAME" TO :"role";
GRANT USAGE ON SCHEMA public TO :"role";
EOSQL
