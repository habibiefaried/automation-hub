#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password';
EOSQL

cat >> "$PGDATA/pg_hba.conf" <<EOF

local   all             all                                     trust
host    replication     replicator      all                     scram-sha-256
host    all             all             all                     scram-sha-256
EOF

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT pg_reload_conf();
EOSQL

echo "Replication configured successfully"
