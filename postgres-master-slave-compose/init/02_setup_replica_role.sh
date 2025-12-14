#!/bin/bash
set -e

# This script ensures the replicator role exists on replica servers
# Note: Replicas created via pg_basebackup inherit all roles from master,
# so this script is mainly for verification or manual setup scenarios
# It's safe to run even if the role already exists

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
            CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password';
            RAISE NOTICE 'Replicator role created on replica';
        ELSE
            RAISE NOTICE 'Replicator role already exists on replica';
        END IF;
    END
    \$\$;
EOSQL

echo "Replicator role verified on replica"

