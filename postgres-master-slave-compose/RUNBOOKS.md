# Operational Runbooks

This document contains operational runbooks for managing the PostgreSQL master-slave replication setup.

## TLDR

**Promote Replica to Master (Failover) - Quick Steps:**

1. **Verify master is down:**
   ```bash
   docker ps -a | grep postgres_primary
   ```

2. **Choose best replica** (check WAL lag):
   ```bash
   docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
     "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"
   ```

3. **Promote replica:**
   ```bash
   docker exec -it postgres_replica_01 psql -U postgres -d postgres -c "SELECT pg_promote();"
   ```

4. **Update other replicas** (change DNS in config):
   ```bash
   docker exec postgres_replica_02 bash -c \
     "sed -i 's/host=postgres_primary/host=postgres_replica_01/g' /var/lib/postgresql/data/postgresql.auto.conf"
   docker restart postgres_replica_02
   ```

5. **Update PgCat config** (inside container):
   ```bash
   docker exec pgcat bash -c \
     "sed -i 's/\[\"postgres_replica_01\", 5432, \"replica\"\]/[\"postgres_replica_01\", 5432, \"primary\"]/' /etc/pgcat/pgcat.toml"
   docker restart pgcat
   ```

**Key Points:**
- ⚠️ **No Docker Compose file changes** - all updates via `docker exec`
- ✅ **Promote with** `pg_promote()` (PostgreSQL 9.6+)
- ✅ **Update replica DNS** in `postgresql.auto.conf`
- ✅ **Update PgCat** config inside container
- ✅ **Verify** with `pg_is_in_recovery()` and test writes

**Estimated Time:** 10-15 minutes

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

**Important**: This runbook uses `docker exec` to update configurations inside containers. No Docker Compose files are modified.

### Step 1: Verify Master Failure

First, confirm that the master is indeed down and cannot be recovered:

```bash
# Check if master container is running
docker ps -a | grep postgres_primary

# Check master container logs
docker logs postgres_primary

# Try to connect to master (should fail)
docker exec -it postgres_primary psql -U postgres -d postgres -c "SELECT 1;" 2>&1 || echo "Master is down"
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

### Step 3: Promote the Replica to Master

Promote the chosen replica using `pg_promote()`:

```bash
# Promote using pg_promote (works while container is running)
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_promote();"

# Wait a moment for promotion to complete
sleep 3

# Verify promotion
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery();"
```

**Expected Result**: `pg_is_in_recovery()` should return `f` (false), indicating it's no longer a replica.

### Step 4: Update Replication Setup on New Master

Ensure the new master has the replicator role configured:

```bash
# Connect to new master and create replicator role if it doesn't exist
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password'; END IF; END \$\$;"

# Verify the replicator role exists
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"

# Create replication slots for other replicas (optional but recommended)
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_create_physical_replication_slot('replica_02_slot') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_02_slot');"

docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_create_physical_replication_slot('replica_03_slot') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_03_slot');"

docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_create_physical_replication_slot('replica_04_slot') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_04_slot');"

docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT pg_create_physical_replication_slot('replica_05_slot') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_05_slot');"

# Verify slots
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT * FROM pg_replication_slots;"
```

### Step 5: Update Other Replicas to Point to New Master

Update each remaining replica's configuration to point to the new master. We'll edit the file inside the running container, then restart it:

```bash
# For each replica (02, 03, 04, 05), update the primary_conninfo
# We'll update postgresql.auto.conf inside each running container

# Replica 02: Edit config inside running container
docker exec postgres_replica_02 bash -c \
  "sed -i 's/host=postgres_primary/host=postgres_replica_01/g' /var/lib/postgresql/data/postgresql.auto.conf"

# Restart replica 02 to pick up the changes
docker restart postgres_replica_02

# Wait and verify it's connecting to new master
sleep 5
docker exec -it postgres_replica_02 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

# Repeat for Replica 03
docker exec postgres_replica_03 bash -c \
  "sed -i 's/host=postgres_primary/host=postgres_replica_01/g' /var/lib/postgresql/data/postgresql.auto.conf"
docker restart postgres_replica_03
sleep 5

# Repeat for Replica 04
docker exec postgres_replica_04 bash -c \
  "sed -i 's/host=postgres_primary/host=postgres_replica_01/g' /var/lib/postgresql/data/postgresql.auto.conf"
docker restart postgres_replica_04
sleep 5

# Repeat for Replica 05
docker exec postgres_replica_05 bash -c \
  "sed -i 's/host=postgres_primary/host=postgres_replica_01/g' /var/lib/postgresql/data/postgresql.auto.conf"
docker restart postgres_replica_05
sleep 5
```

**Alternative Method** (if sed doesn't work, manually edit the file):

```bash
# For each replica, you can view and edit the config file inside the running container
docker exec -it postgres_replica_02 cat /var/lib/postgresql/data/postgresql.auto.conf

# Or use a text editor inside the container
docker exec -it postgres_replica_02 bash
# Then inside the container:
# vi /var/lib/postgresql/data/postgresql.auto.conf
# Change: primary_conninfo = 'host=postgres_primary ...'
# To:     primary_conninfo = 'host=postgres_replica_01 ...'
# Exit the container, then restart it:
# docker restart postgres_replica_02
```

**Note**: The `postgresql.auto.conf` file contains a line like:
```
primary_conninfo = 'host=postgres_primary port=5432 user=replicator password=replicator_password'
```

Change `postgres_primary` to `postgres_replica_01` (or whichever replica you promoted).

### Step 6: Update PgCat Configuration

Update PgCat configuration inside its container to point to the new master:

```bash
# First, backup the current config inside the container
docker exec pgcat cp /etc/pgcat/pgcat.toml /etc/pgcat/pgcat.toml.backup

# View current config
docker exec pgcat cat /etc/pgcat/pgcat.toml

# Update the config: Change postgres_replica_01 from "replica" to "primary"
# And comment out or remove postgres_primary
docker exec pgcat bash -c \
  "sed -i 's/\[\"postgres_replica_01\", 5432, \"replica\"\]/[\"postgres_replica_01\", 5432, \"primary\"]/' /etc/pgcat/pgcat.toml"

# Comment out the old primary line
docker exec pgcat bash -c \
  "sed -i 's/\[\"postgres_primary\", 5432, \"primary\"\]/\/\/ [\"postgres_primary\", 5432, \"primary\"]/' /etc/pgcat/pgcat.toml"

# Verify the changes
docker exec pgcat cat /etc/pgcat/pgcat.toml | grep -A 10 "servers ="
```

**Alternative Method** (manual edit):

```bash
# If sed doesn't work, you can edit the file directly
docker exec -it pgcat bash
# Inside the container:
# vi /etc/pgcat/pgcat.toml
# Or use cat and echo to rebuild the file
```

**Expected config change**:
```toml
# Before:
servers = [
    ["postgres_primary", 5432, "primary"],
    ["postgres_replica_01", 5432, "replica"],
    ...

# After:
servers = [
    // ["postgres_primary", 5432, "primary"],  # Commented out
    ["postgres_replica_01", 5432, "primary"],  # Changed to primary
    ...
```

### Step 7: Reload PgCat Configuration

Reload PgCat to pick up the new configuration. PgCat may support SIGHUP for reload, or you may need to restart:

```bash
# Try to reload PgCat (sends SIGHUP)
docker kill -s SIGHUP pgcat

# Wait a moment
sleep 3

# If that doesn't work, restart the container
docker restart pgcat

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

### Step 9: Verify Replicas are Connected to New Master

Check that all replicas are now replicating from the new master:

```bash
# Check replication status on new master
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT application_name, state, sync_state, client_addr FROM pg_stat_replication;"

# Verify replicator role exists on new master
docker exec -it postgres_replica_01 psql -U postgres -d postgres -c \
  "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"

# Verify each replica is in recovery mode and connected
# Also verify replicator role exists on each replica
docker exec -it postgres_replica_02 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

docker exec -it postgres_replica_02 psql -U postgres -d postgres -c \
  "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"

docker exec -it postgres_replica_03 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

docker exec -it postgres_replica_03 psql -U postgres -d postgres -c \
  "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"

docker exec -it postgres_replica_04 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

docker exec -it postgres_replica_04 psql -U postgres -d postgres -c \
  "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"

docker exec -it postgres_replica_05 psql -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

docker exec -it postgres_replica_05 psql -U postgres -d postgres -c \
  "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"
```

**Expected Results**:
- All replicas show `pg_is_in_recovery()` = `t` (true)
- New master shows 4 active replication connections
- WAL positions on replicas should be advancing

### Step 10: Final Verification

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
docker ps | grep postgres
```

### Rollback Procedure (If Needed)

If you need to rollback the promotion:

```bash
# 1. Restore PgCat config from backup
docker exec pgcat cp /etc/pgcat/pgcat.toml.backup /etc/pgcat/pgcat.toml
docker restart pgcat

# 2. If old master is recoverable, restart it
docker start postgres_primary

# 3. Revert the promoted replica back to replica mode
# (This is complex and may require recreating the replica)
```

### Troubleshooting

#### Issue: Promotion Fails

**Symptom**: `pg_promote()` returns false or errors.

**Solution**:
- Check replica logs: `docker logs postgres_replica_01`
- Verify the replica is actually in recovery mode: `docker exec postgres_replica_01 psql -U postgres -c "SELECT pg_is_in_recovery();"`
- Try the alternative method (removing standby.signal file)
- Check PostgreSQL version supports `pg_promote()` (PostgreSQL 9.6+)

#### Issue: PgCat Cannot Connect to New Master

**Symptom**: PgCat logs show connection errors.

**Solution**:
- Verify new master is running: `docker ps | grep postgres_replica_01`
- Check network connectivity: `docker network inspect postgres-master-slave-compose_postgres_network`
- Verify PgCat config inside container: `docker exec pgcat cat /etc/pgcat/pgcat.toml`
- Check if config was updated correctly: `docker exec pgcat grep -A 5 "servers =" /etc/pgcat/pgcat.toml`
- Restart PgCat: `docker restart pgcat`
- Check PgCat logs: `docker logs pgcat --tail 50`

#### Issue: Other Replicas Won't Connect to New Master

**Symptom**: Replicas show connection errors to new master.

**Solution**:
- Verify replication user exists on new master: `docker exec postgres_replica_01 psql -U postgres -c "\du replicator"`
- Check the primary_conninfo was updated: `docker exec postgres_replica_02 cat /var/lib/postgresql/data/postgresql.auto.conf | grep primary_conninfo`
- Verify the hostname in primary_conninfo matches the new master container name
- Check `pg_hba.conf` allows replication connections: `docker exec postgres_replica_01 cat /var/lib/postgresql/data/pg_hba.conf | grep replication`
- Verify network connectivity: `docker exec postgres_replica_02 ping -c 2 postgres_replica_01`
- Check replica logs: `docker logs postgres_replica_02`

#### Issue: sed Command Fails in Container

**Symptom**: `sed` command returns error or doesn't work.

**Solution**:
- Check if sed is available: `docker exec postgres_replica_02 which sed`
- Use alternative: Edit the file manually with `vi` or `nano` inside the container
- Or use `cat` and `echo` to rebuild the config file
- Verify file permissions: `docker exec postgres_replica_02 ls -la /var/lib/postgresql/data/postgresql.auto.conf`

#### Issue: PgCat Config Update Doesn't Take Effect

**Symptom**: PgCat still routes to old master after config update.

**Solution**:
- Verify config was actually updated: `docker exec pgcat cat /etc/pgcat/pgcat.toml`
- Check if PgCat supports SIGHUP reload or needs full restart
- Restart PgCat container: `docker restart pgcat`
- Check PgCat logs for errors: `docker logs pgcat`
- Verify the config file syntax is correct (TOML format)

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
- **This runbook does NOT modify Docker Compose files** - all changes are made inside containers using `docker exec`
- Always test these procedures in a non-production environment first
- Keep backups before performing any destructive operations
- Document any environment-specific variations
- Container names (DNS names) are used for inter-container communication, so updating `primary_conninfo` to point to the new master container name is critical
- PgCat configuration is updated inside the container, not in the host file system

