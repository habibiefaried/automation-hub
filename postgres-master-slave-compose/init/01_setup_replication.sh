#!/bin/bash
set -e

# Create replicator role if it doesn't exist (idempotent)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
            CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password';
            RAISE NOTICE 'Replicator role created on master';
        ELSE
            RAISE NOTICE 'Replicator role already exists on master';
        END IF;
    END
    \$\$;
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
