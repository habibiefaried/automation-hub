# PostgreSQL Master-Slave Replication with PgCat

This repository contains Docker Compose configurations for PostgreSQL master-slave replication setups with PgCat connection pooling.

## TLDR

**Quick Start:**
```bash
# Standard setup (1 master + 1 replica)
docker-compose up -d

# Massive setup (1 master + 5 replicas)
docker-compose -f docker-compose-massive.yml up -d
```

**Connect via PgCat:**
```bash
psql -h localhost -p 6432 -U postgres -d postgres
# Password: password
```

**Key Points:**
- ✅ **1 master + 1-5 replicas** (PostgreSQL 16)
- ✅ **PgCat** routes writes → master, reads → replicas
- ✅ **Streaming replication** for real-time sync
- ✅ **Port 6432** for application connections
- ✅ **Health checks** ensure proper startup order
- ✅ **Replicator role** auto-created on master, inherited by replicas

**Credentials:**
- Host: `localhost`
- Port: `6432`
- Username: `postgres`
- Password: `password`
- Database: `postgres`

## Overview

This setup provides two configurations:

1. **Standard Setup** (`docker-compose.yml`): 1 master + 1 replica
2. **Massive Setup** (`docker-compose-massive.yml`): 1 master + 5 replicas

Both configurations use:
- **PostgreSQL 16** for the database servers
- **PgCat** as a connection pooler and query router
- **Streaming replication** for real-time data synchronization
- **Health checks** to ensure services start in the correct order

## Architecture

### Massive Setup (1 Master + 5 Replicas + 3 PgCat)

```
┌─────────────────┐
│   Application   │
└────────┬────────┘
         │
    ┌────┼────┐
    │    │    │
    │ Port 6432, 6433, 6434
    │    │    │
┌───▼──┐┌───▼──┐┌───▼──┐
│PgCat ││PgCat ││PgCat │  Connection Poolers & Query Routers
│  01  ││  02  ││  03  │  (High Availability - No SPOF)
└───┬──┘└───┬──┘└───┬──┘
    │       │       │
    └───┬───┴───┬───┘
        │       │
    ┌───┴───┬───┴───┬──────────┬──────────┬──────────┐
    │       │       │          │          │          │
┌───▼───┐ ┌───▼───┐ ┌───▼───┐ ┌───▼───┐ ┌───▼───┐ ┌───▼───┐
│Primary│ │Replica│ │Replica│ │Replica│ │Replica│ │Replica│
│       │ │  01   │ │  02   │ │  03   │ │  04   │ │  05   │
└───────┘ └───────┘ └───────┘ └───────┘ └───────┘ └───────┘
    │         │          │          │          │          │
    └─────────┴──────────┴──────────┴──────────┴──────────┘
              Streaming Replication (WAL)
```

### Components

- **postgres_primary**: Master database server (accepts writes)
- **postgres_replica_01 to 05**: Read replicas (synchronized via streaming replication)
- **pgcat_01, pgcat_02, pgcat_03**: Connection poolers (3 instances for high availability, no SPOF)
  - **Ports**: 6432, 6433, 6434 (respectively)
  - **Function**: Routes:
    - **Writes** (INSERT, UPDATE, DELETE) → Primary
    - **Reads** (SELECT) → Replicas (load balanced)
  - **High Availability**: Applications can connect to any of the 3 PgCat instances

## Prerequisites

- Docker and Docker Compose installed
- `psql` client (PostgreSQL client) installed (optional, for testing)
- At least 2GB of free disk space
- Port 6432 available on your host

## Quick Start

### Standard Setup (1 Master + 1 Replica)

```bash
# Start all services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f
```

### Massive Setup (1 Master + 5 Replicas)

```bash
# Start all services
docker-compose -f docker-compose-massive.yml up -d

# Check status
docker-compose -f docker-compose-massive.yml ps

# View logs
docker-compose -f docker-compose-massive.yml logs -f
```

**Note**: The first startup may take a few minutes as each replica performs a base backup from the primary.

## Connection Information

### Connect via PgCat (Recommended)

PgCat acts as a single entry point and automatically routes queries:

```bash
# Using psql
psql -h localhost -p 6432 -U postgres -d postgres

# Or with password in command
PGPASSWORD=password psql -h localhost -p 6432 -U postgres -d postgres
```

**Credentials:**
- **Host**: `localhost`
- **Port**: `6432`
- **Username**: `postgres`
- **Password**: `password`
- **Database**: `postgres`

### Direct Connection to Primary

```bash
# Direct connection to primary (bypasses PgCat)
docker exec -it postgres_primary psql -U postgres -d postgres
```

### Direct Connection to Replicas

```bash
# Connect to replica 01
docker exec -it postgres_replica_01 psql -U postgres -d postgres

# Connect to replica 02
docker exec -it postgres_replica_02 psql -U postgres -d postgres

# ... and so on for replicas 03, 04, 05
```

## Testing Write/Read Scenarios

### Test 1: Verify Write Operations Go to Primary

This test confirms that write operations are routed to the primary server.

```bash
# Connect via PgCat
psql -h localhost -p 6432 -U postgres -d postgres
```

```sql
-- Insert test data (will be routed to primary)
INSERT INTO test_table (name) VALUES ('write_test_' || NOW()::text);

-- Verify the data was inserted
SELECT id, name, created_at 
FROM test_table 
ORDER BY id DESC 
LIMIT 1;
```

**Expected Result**: The INSERT succeeds and the data is visible immediately.

### Test 2: Verify Read Operations Can Use Replicas

With `pool_mode = "transaction"`, read queries within a transaction can be routed to replicas.

```sql
-- Start a read-only transaction
BEGIN READ ONLY;

-- These queries may be routed to any of the 5 replicas
SELECT COUNT(*) FROM test_table;
SELECT * FROM test_table ORDER BY id DESC LIMIT 5;

COMMIT;
```

**Expected Result**: Queries execute successfully and may be load-balanced across replicas.

### Test 3: Verify Replication is Working

This test confirms that data written to the primary is replicated to all replicas.

```bash
# Step 1: Insert data via PgCat (goes to primary)
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "INSERT INTO test_table (name) VALUES ('replication_test_' || NOW()::text);"

# Step 2: Wait a few seconds for replication
sleep 3

# Step 3: Check data on primary
docker exec -it postgres_primary psql -U postgres -d postgres -c \
  "SELECT id, name, created_at FROM test_table ORDER BY id DESC LIMIT 1;"

# Step 4: Check data on each replica
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT id, name, created_at FROM test_table ORDER BY id DESC LIMIT 1;"

docker exec -it postgres_replica_02 psql -U postgres -d postgres -c \
  "SELECT id, name, created_at FROM test_table ORDER BY id DESC LIMIT 1;"

# ... repeat for replicas 03, 04, 05
```

**Expected Result**: The same data appears on the primary and all replicas (may have slight delay on replicas).

### Test 4: Load Balancing Test

This test verifies that read queries are distributed across multiple replicas.

```bash
# Connect via PgCat
psql -h localhost -p 6432 -U postgres -d postgres
```

```sql
-- Execute multiple read queries
BEGIN READ ONLY;
SELECT 'Query 1' as query, COUNT(*) FROM test_table;
SELECT 'Query 2' as query, COUNT(*) FROM test_table;
SELECT 'Query 3' as query, COUNT(*) FROM test_table;
SELECT 'Query 4' as query, COUNT(*) FROM test_table;
SELECT 'Query 5' as query, COUNT(*) FROM test_table;
COMMIT;
```

**Verification**: Check PgCat logs to see which replica handled each query:

```bash
docker logs pgcat | grep -i replica
```

### Test 5: Write-Read Consistency Test

This test verifies that writes are immediately visible for subsequent reads.

```sql
-- Connect via PgCat
psql -h localhost -p 6432 -U postgres -d postgres

-- Write data
INSERT INTO test_table (name) VALUES ('consistency_test_' || NOW()::text)
RETURNING id, name;

-- Immediately read it back
SELECT id, name, created_at 
FROM test_table 
WHERE name LIKE 'consistency_test_%' 
ORDER BY id DESC 
LIMIT 1;
```

**Expected Result**: The data is immediately visible, even if the read goes to a replica (due to streaming replication).

### Test 6: Concurrent Write Test

Test multiple concurrent write operations.

```bash
# Run multiple inserts in parallel
for i in {1..10}; do
  psql -h localhost -p 6432 -U postgres -d postgres -c \
    "INSERT INTO test_table (name) VALUES ('concurrent_test_$i');" &
done
wait

# Verify all inserts succeeded
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "SELECT COUNT(*) FROM test_table WHERE name LIKE 'concurrent_test_%';"
```

**Expected Result**: All 10 inserts succeed and are visible.

## Monitoring and Verification

### Check Service Status

```bash
# Standard setup
docker-compose ps

# Massive setup
docker-compose -f docker-compose-massive.yml ps
```

### View Logs

```bash
# All services
docker-compose -f docker-compose-massive.yml logs -f

# Specific service
docker-compose -f docker-compose-massive.yml logs -f postgres_primary
docker-compose -f docker-compose-massive.yml logs -f pgcat
```

### Check Replication Status

#### On Primary

```bash
docker exec -it postgres_primary psql -U postgres -d postgres -c \
  "SELECT application_name, state, sync_state, sync_priority, client_addr 
   FROM pg_stat_replication;"
```

**Expected Result**: You should see 5 rows (one for each replica) with `state = 'streaming'`.

#### Check Replication Lag

```bash
# On primary - get current WAL position
docker exec -it postgres_primary psql -U postgres -d postgres -c \
  "SELECT pg_current_wal_lsn();"

# On replica - get last replayed WAL position
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_last_wal_replay_lsn();"
```

**Expected Result**: The replica's LSN should be close to or equal to the primary's LSN (small lag is normal).

### Check PgCat Status

```bash
# View PgCat logs
docker logs pgcat

# Check PgCat admin interface (if enabled)
# Note: Admin interface configuration may vary by PgCat version
```

### Verify Replica Read-Only Status

Replicas should be in read-only mode:

```bash
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SHOW transaction_read_only;"
```

**Expected Result**: `transaction_read_only = on`

## Configuration Details

### PostgreSQL Primary Configuration

- **WAL Level**: `replica` (enables streaming replication)
- **Max WAL Senders**: `10` (supports up to 10 concurrent replicas)
- **Max Replication Slots**: `10` (prevents WAL deletion if replica is down)
- **Hot Standby**: `on` (allows read queries on replicas)

### Replication User (Replicator Role)

- **Role Name**: `replicator`
- **Password**: `replicator_password`
- **Created On**: Master (via `init/01_setup_replication.sh`)
- **Inherited By**: Replicas (automatically copied via `pg_basebackup`)
- **Purpose**: Used for streaming replication between master and replicas

The replicator role is created on the master during initialization and is automatically available on all replicas since `pg_basebackup` copies the entire data directory including all roles.

### PgCat Configuration

- **Pool Mode**: `transaction` (routes writes to primary, reads to replicas)
- **Port**: `6432`
- **Pool Size**: `10` connections per pool
- **Servers**: 1 primary + 5 replicas (in massive setup)

## Troubleshooting

### Replicas Not Starting

**Symptom**: Replicas fail to start or show errors.

**Solution**:
1. Check primary is healthy: `docker-compose ps postgres_primary`
2. Verify replication user exists: Check `init/01_setup_replication.sh`
3. Check logs: `docker-compose logs postgres_replica_01`

### Replication Lag

**Symptom**: Data appears on primary but not on replicas.

**Solution**:
1. Check replication status: `SELECT * FROM pg_stat_replication;` on primary
2. Verify network connectivity between containers
3. Check replica logs for errors
4. Ensure `max_wal_senders` is sufficient (currently 10)

### Cannot Connect to PgCat

**Symptom**: Connection refused on port 6432.

**Solution**:
1. Check PgCat is running: `docker-compose ps pgcat`
2. Verify port mapping: `docker port pgcat`
3. Check PgCat logs: `docker logs pgcat`
4. Ensure all dependencies (primary and replicas) are healthy

### Write Operations Failing

**Symptom**: INSERT/UPDATE/DELETE operations fail.

**Solution**:
1. Verify connection is going through PgCat (port 6432)
2. Check primary is healthy: `docker-compose ps postgres_primary`
3. Check PgCat configuration: `cat pgcat/pgcat-massive.toml`
4. Review PgCat logs for routing errors

### Replica Out of Sync

**Symptom**: Replica shows old data or errors.

**Solution**:
1. Check replication status on primary
2. Restart the affected replica: `docker-compose restart postgres_replica_01`
3. If persistent, remove replica volume and recreate:
   ```bash
   docker-compose stop postgres_replica_01
   docker volume rm postgres-master-slave-compose_postgres_replica_01_data
   docker-compose up -d postgres_replica_01
   ```

## Cleanup

### Stop Services

```bash
# Standard setup
docker-compose down

# Massive setup
docker-compose -f docker-compose-massive.yml down
```

### Remove All Data (⚠️ Destructive)

```bash
# Standard setup
docker-compose down -v

# Massive setup
docker-compose -f docker-compose-massive.yml down -v
```

**Warning**: This will delete all database data!

## Files Structure

```
postgres-master-slave-compose/
├── docker-compose.yml              # Standard setup (1 master + 1 replica)
├── docker-compose-massive.yml      # Massive setup (1 master + 5 replicas)
├── README.md                       # This file
├── init/
│   ├── 00_init.sql                 # Initial database schema
│   └── 01_setup_replication.sh    # Replication user setup
└── pgcat/
    ├── pgcat.toml                  # PgCat config for standard setup
    └── pgcat-massive.toml          # PgCat config for massive setup
```

## Security Notes

⚠️ **This setup is for development/testing purposes only!**

For production use, consider:
- Changing default passwords
- Using secrets management
- Enabling SSL/TLS connections
- Restricting network access
- Implementing proper backup strategies
- Monitoring and alerting
- Regular security updates

## License

See the main repository license file.

## References

- [PostgreSQL Streaming Replication](https://www.postgresql.org/docs/current/high-availability.html)
- [PgCat Documentation](https://github.com/postgresml/pgcat)
- [Docker Compose Documentation](https://docs.docker.com/compose/)

