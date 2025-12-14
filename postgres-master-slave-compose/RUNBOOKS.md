# Operational Runbooks

This document contains operational runbooks for managing the PostgreSQL master-slave replication setup.

## Table of Contents

1. [Promote Replica to Master (Failover)](#promote-replica-to-master-failover)

---

## Promote Replica to Master (Failover)

**Scenario**: The primary/master PostgreSQL container is down or unrecoverable, and you need to promote one of the replicas to become the new master.

**Prerequisites**:
- Docker and Docker Compose installed
- Access to the host machine running the containers
- Understanding of which replica has the least replication lag (preferably)

**Estimated Time**: 10-15 minutes

### Step 1: Verify Master Failure

First, confirm that the master is indeed down and cannot be recovered:

```bash
# Check if master container is running
docker ps -a | grep postgres_primary

# Check master container logs
docker logs postgres_primary

# Try to connect to master (should fail)
docker exec -it postgres_primary psql -U postgres -d postgres -c "SELECT 1;" || echo "Master is down"
```

**Decision Point**: If the master can be recovered quickly, do that instead of promoting a replica.

### Step 2: Check Replica Status and Choose Best Candidate

Check which replicas are available and determine which one has the least replication lag:

```bash
# Check all replica containers
docker ps -a | grep postgres_replica

# For each replica, check if it's in recovery mode and get WAL position
# Replica 01
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

# Replica 02
docker exec -it postgres_replica_02 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

# Replica 03
docker exec -it postgres_replica_03 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

# Replica 04
docker exec -it postgres_replica_04 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

# Replica 05
docker exec -it postgres_replica_05 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"
```

**Note**: The replica with the highest `pg_last_wal_replay_lsn()` value has the least lag. Choose this one for promotion.

**For this runbook, we'll assume `postgres_replica_01` is chosen as the new master.**

### Step 3: Stop the Chosen Replica

Stop the replica container that will be promoted:

```bash
# Stop the replica container
docker-compose -f docker-compose-massive.yml stop postgres_replica_01

# Verify it's stopped
docker ps -a | grep postgres_replica_01
```

### Step 4: Promote the Replica to Master

There are two methods to promote a replica. Method 1 (using pg_promote) is recommended for PostgreSQL 9.6+.

#### Method 1: Using pg_promote (Recommended)

```bash
# Start the container temporarily to run pg_promote
docker-compose -f docker-compose-massive.yml up -d postgres_replica_01

# Wait a few seconds for it to start
sleep 5

# Promote using pg_promote
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_promote();"

# Verify promotion
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery();"
```

**Expected Result**: `pg_is_in_recovery()` should return `f` (false), indicating it's no longer a replica.

#### Method 2: Manual Promotion (Alternative)

If `pg_promote()` doesn't work, you can manually promote:

```bash
# Stop the container
docker-compose -f docker-compose-massive.yml stop postgres_replica_01

# Remove the standby.signal or recovery.signal file
docker run --rm -v postgres-master-slave-compose_postgres_replica_01_data:/data \
  postgres:16 sh -c "rm -f /data/standby.signal /data/recovery.signal"

# Start the container
docker-compose -f docker-compose-massive.yml up -d postgres_replica_01

# Wait and verify
sleep 5
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery();"
```

### Step 5: Update Docker Compose Configuration

Update the docker-compose file to reflect the new master. You have two options:

#### Option A: Rename Containers (Recommended for Long-term)

This involves updating `docker-compose-massive.yml` to swap the roles:

1. **Backup the current master data** (if you want to keep it):
   ```bash
   # Note: This is optional, only if you want to preserve old master data
   docker volume inspect postgres-master-slave-compose_postgres_primary_data
   ```

2. **Update docker-compose-massive.yml**:
   - Change `postgres_replica_01` service to become the new primary
   - Optionally, rename `postgres_primary` to become a replica or remove it

#### Option B: Quick Fix (Temporary Solution)

For a quick fix without modifying docker-compose, we'll update PgCat to point to the promoted replica as the primary.

### Step 6: Update PgCat Configuration

Update PgCat to recognize the promoted replica as the new primary:

```bash
# Backup current PgCat config
cp pgcat/pgcat-massive.toml pgcat/pgcat-massive.toml.backup

# Edit the PgCat configuration
# Change postgres_replica_01 from "replica" to "primary"
# And optionally remove or comment out postgres_primary
```

**Manual Edit Required**: Edit `pgcat/pgcat-massive.toml`:

```toml
[pools.postgres.shards.0]
servers = [
    ["postgres_replica_01", 5432, "primary"],  # Changed from replica to primary
    ["postgres_replica_02", 5432, "replica"],
    ["postgres_replica_03", 5432, "replica"],
    ["postgres_replica_04", 5432, "replica"],
    ["postgres_replica_05", 5432, "replica"]
    # ["postgres_primary", 5432, "primary"],  # Commented out or removed
]
```

**Or use sed (Linux/Mac/Git Bash)**:

```bash
# Update pgcat-massive.toml to make replica_01 the primary
sed -i 's/\["postgres_replica_01", 5432, "replica"\]/["postgres_replica_01", 5432, "primary"]/' pgcat/pgcat-massive.toml

# Comment out or remove the old primary line
sed -i 's/\["postgres_primary", 5432, "primary"\]/\/\/ ["postgres_primary", 5432, "primary"]/' pgcat/pgcat-massive.toml
```

### Step 7: Restart PgCat

Restart PgCat to pick up the new configuration:

```bash
# Restart PgCat
docker-compose -f docker-compose-massive.yml restart pgcat

# Wait for it to start
sleep 5

# Check PgCat logs
docker logs pgcat --tail 50
```

### Step 8: Verify the New Master

Verify that the promoted replica is now functioning as the master:

```bash
# Connect via PgCat
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), version();"

# Test write operation
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "INSERT INTO test_table (name) VALUES ('failover_test_' || NOW()::text) RETURNING id, name;"

# Verify the write succeeded
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "SELECT * FROM test_table WHERE name LIKE 'failover_test_%' ORDER BY id DESC LIMIT 1;"
```

**Expected Results**:
- `pg_is_in_recovery()` returns `f` (false)
- Write operations succeed
- Data is visible immediately

### Step 9: Handle Other Replicas (Optional)

The other replicas (`postgres_replica_02` through `postgres_replica_05`) are still trying to replicate from the old master. You have two options:

#### Option A: Reconfigure Other Replicas to Point to New Master

This requires updating each replica's `postgresql.auto.conf` or `recovery.conf`:

```bash
# For each remaining replica, you'll need to:
# 1. Stop the replica
docker-compose -f docker-compose-massive.yml stop postgres_replica_02

# 2. Update the primary_conninfo in the data directory
# This is complex and may require recreating the replica from the new master
# See "Recreate Replicas" section below
```

#### Option B: Recreate Replicas from New Master (Recommended)

The cleanest approach is to recreate the other replicas from the new master:

```bash
# Stop all remaining replicas
docker-compose -f docker-compose-massive.yml stop postgres_replica_02 postgres_replica_03 postgres_replica_04 postgres_replica_05

# Remove their data volumes (⚠️ This deletes their data)
docker volume rm postgres-master-slave-compose_postgres_replica_02_data
docker volume rm postgres-master-slave-compose_postgres_replica_03_data
docker volume rm postgres-master-slave-compose_postgres_replica_04_data
docker volume rm postgres-master-slave-compose_postgres_replica_05_data

# Update docker-compose-massive.yml to point replicas to new master
# Change the hostname in the replica command from "postgres_primary" to "postgres_replica_01"

# Restart replicas (they will recreate from new master)
docker-compose -f docker-compose-massive.yml up -d postgres_replica_02 postgres_replica_03 postgres_replica_04 postgres_replica_05
```

**Note**: You'll need to update the `01_setup_replication.sh` script or manually create replication slots on the new master first.

### Step 10: Update Replication Setup on New Master

The new master needs to have the replication user and slots configured:

```bash
# Connect to new master
docker exec -it postgres_replica_01 psql -U postgres -d postgres

# Create replication user if it doesn't exist
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password';

# Create replication slots for other replicas (optional but recommended)
SELECT pg_create_physical_replication_slot('replica_02_slot');
SELECT pg_create_physical_replication_slot('replica_03_slot');
SELECT pg_create_physical_replication_slot('replica_04_slot');
SELECT pg_create_physical_replication_slot('replica_05_slot');

# Verify slots
SELECT * FROM pg_replication_slots;
```

### Step 11: Final Verification

Perform comprehensive verification:

```bash
# 1. Verify new master is not in recovery
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery();"

# 2. Test writes via PgCat
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "INSERT INTO test_table (name) VALUES ('final_test_' || NOW()::text);"

# 3. Test reads via PgCat
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "SELECT COUNT(*) FROM test_table;"

# 4. Check PgCat is routing correctly
docker logs pgcat --tail 20

# 5. Verify all services are running
docker-compose -f docker-compose-massive.yml ps
```

### Step 12: Update Documentation

Update any documentation or configuration that references the old master:

- Update `docker-compose-massive.yml` if you made temporary changes
- Update any application connection strings
- Document the failover event and timestamp
- Note which replica was promoted

### Rollback Procedure (If Needed)

If you need to rollback the promotion:

```bash
# 1. Stop the promoted replica
docker-compose -f docker-compose-massive.yml stop postgres_replica_01

# 2. Restore original PgCat config
cp pgcat/pgcat-massive.toml.backup pgcat/pgcat-massive.toml

# 3. Restart PgCat
docker-compose -f docker-compose-massive.yml restart pgcat

# 4. If old master is recoverable, restart it
docker-compose -f docker-compose-massive.yml up -d postgres_primary
```

### Troubleshooting

#### Issue: Promotion Fails

**Symptom**: `pg_promote()` returns false or errors.

**Solution**:
- Check replica logs: `docker logs postgres_replica_01`
- Verify data directory permissions
- Try Method 2 (manual promotion)

#### Issue: PgCat Cannot Connect to New Master

**Symptom**: PgCat logs show connection errors.

**Solution**:
- Verify new master is running: `docker ps | grep postgres_replica_01`
- Check network connectivity: `docker network inspect postgres-master-slave-compose_postgres_network`
- Verify PgCat config syntax: Check `pgcat/pgcat-massive.toml`
- Restart PgCat: `docker-compose restart pgcat`

#### Issue: Other Replicas Won't Connect to New Master

**Symptom**: Replicas show connection errors to new master.

**Solution**:
- Verify replication user exists on new master
- Check `pg_hba.conf` allows replication connections
- Verify network connectivity between containers
- Consider recreating replicas from new master

### Prevention and Best Practices

1. **Monitor Replication Lag**: Set up monitoring to alert on high replication lag
2. **Regular Backups**: Take regular backups of the master
3. **Test Failover**: Periodically test failover procedures in a non-production environment
4. **Documentation**: Keep this runbook updated with any environment-specific changes
5. **Automation**: Consider using tools like Patroni or repmgr for automated failover

### Post-Failover Tasks

After a successful failover:

1. **Investigate Root Cause**: Determine why the original master failed
2. **Recover Old Master**: If possible, recover and reconfigure the old master as a replica
3. **Update Monitoring**: Update monitoring systems to point to the new master
4. **Notify Team**: Inform the team about the failover
5. **Review Logs**: Review logs from the time of failure
6. **Document Incident**: Document the incident, timeline, and resolution

---

## Future Runbooks

Additional runbooks to be added:

- [ ] Recreate Replicas from Master
- [ ] Add New Replica to Existing Setup
- [ ] Remove Replica from Setup
- [ ] Backup and Restore Procedures
- [ ] Scale Up/Down Replicas
- [ ] Update PostgreSQL Version
- [ ] Monitor and Alert Setup

---

## Notes

- All commands assume you're in the `postgres-master-slave-compose` directory
- Replace `postgres_replica_01` with your chosen replica if different
- Always test these procedures in a non-production environment first
- Keep backups before performing any destructive operations
- Document any environment-specific variations

