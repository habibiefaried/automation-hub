# Stress Test Guide

This document provides a batch insert script to stress test the PostgreSQL master-slave replication setup with PgCat, inserting **200,000 records** and monitoring system performance.

## Prerequisites

- Docker Compose setup running (`docker-compose-massive.yml`)
- `psql` client installed
- Basic shell scripting knowledge (bash/PowerShell)

## Batch Insert Script

### Bash Script (Linux/Mac/Git Bash)

Create `stress_test.sh`:

```bash
#!/bin/bash

HOST="localhost"
PORT="6432"
USER="postgres"
DB="postgres"
BATCH_SIZE=5000
TOTAL_RECORDS=200000

echo "=========================================="
echo "PostgreSQL Stress Test - Batch Insert"
echo "=========================================="
echo "Total records: $TOTAL_RECORDS"
echo "Batch size: $BATCH_SIZE"
echo "Number of batches: $((TOTAL_RECORDS / BATCH_SIZE))"
echo "Start time: $(date)"
echo ""

START_TIME=$(date +%s)
BATCH_COUNT=$((TOTAL_RECORDS / BATCH_SIZE))

for i in $(seq 1 $BATCH_COUNT); do
    BATCH_START=$(( (i-1) * BATCH_SIZE + 1 ))
    BATCH_END=$(( i * BATCH_SIZE ))
    
    echo "[$(date +%H:%M:%S)] Batch $i/$BATCH_COUNT: Inserting records $BATCH_START to $BATCH_END"
    
    PGPASSWORD=password psql -h $HOST -p $PORT -U $USER -d $DB -c \
        "INSERT INTO test_table (name) 
         SELECT 'stress_test_' || generate_series($BATCH_START, $BATCH_END)::text || '_' || NOW()::text;" \
        > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "  ✓ Batch $i completed"
    else
        echo "  ✗ Batch $i failed"
        exit 1
    fi
    
    # Show progress every 10 batches
    if [ $((i % 10)) -eq 0 ]; then
        ELAPSED=$(($(date +%s) - START_TIME))
        RECORDS_INSERTED=$((i * BATCH_SIZE))
        RATE=$((RECORDS_INSERTED / ELAPSED))
        echo "  Progress: $RECORDS_INSERTED/$TOTAL_RECORDS records ($RATE records/sec)"
    fi
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=========================================="
echo "Stress Test Completed!"
echo "=========================================="
echo "Total records inserted: $TOTAL_RECORDS"
echo "Total time: ${DURATION} seconds"
echo "Average throughput: $((TOTAL_RECORDS / DURATION)) records/second"
echo "End time: $(date)"
echo "=========================================="
```

**Make it executable and run:**
```bash
chmod +x stress_test.sh
./stress_test.sh
```

### PowerShell Script (Windows)

Create `stress_test.ps1`:

```powershell
$Host = "localhost"
$Port = "6432"
$User = "postgres"
$Database = "postgres"
$BatchSize = 5000
$TotalRecords = 200000

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "PostgreSQL Stress Test - Batch Insert" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Total records: $TotalRecords"
Write-Host "Batch size: $BatchSize"
Write-Host "Number of batches: $([math]::Ceiling($TotalRecords / $BatchSize))"
Write-Host "Start time: $(Get-Date)"
Write-Host ""

$StartTime = Get-Date
$Batches = [math]::Ceiling($TotalRecords / $BatchSize)
$env:PGPASSWORD = "password"

for ($i = 1; $i -le $Batches; $i++) {
    $BatchStart = ($i - 1) * $BatchSize + 1
    $BatchEnd = [math]::Min($i * $BatchSize, $TotalRecords)
    
    $TimeStamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$TimeStamp] Batch $i/$Batches : Inserting records $BatchStart to $BatchEnd"
    
    $Query = "INSERT INTO test_table (name) SELECT 'stress_test_' || generate_series($BatchStart, $BatchEnd)::text || '_' || NOW()::text;"
    
    psql -h $Host -p $Port -U $User -d $Database -c $Query *>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Batch $i completed" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Batch $i failed" -ForegroundColor Red
        exit 1
    }
    
    # Show progress every 10 batches
    if ($i % 10 -eq 0) {
        $Elapsed = (Get-Date) - $StartTime
        $RecordsInserted = $i * $BatchSize
        $Rate = [math]::Round($RecordsInserted / $Elapsed.TotalSeconds, 0)
        Write-Host "  Progress: $RecordsInserted/$TotalRecords records ($Rate records/sec)" -ForegroundColor Yellow
    }
}

$EndTime = Get-Date
$Duration = ($EndTime - $StartTime).TotalSeconds

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Stress Test Completed!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Total records inserted: $TotalRecords"
Write-Host "Total time: $([math]::Round($Duration, 2)) seconds"
Write-Host "Average throughput: $([math]::Round($TotalRecords / $Duration, 0)) records/second"
Write-Host "End time: $(Get-Date)"
Write-Host "==========================================" -ForegroundColor Cyan
```

**Run it:**
```powershell
.\stress_test.ps1
```


## Monitoring During Stress Test

### 1. Monitor PgCat Statistics

**Check PgCat stats via admin interface:**
```bash
# Connect to PgCat admin
psql -h localhost -p 6432 -U admin -d pgbouncer

# Show pool statistics
SHOW POOLS;

# Show server statistics
SHOW SERVERS;

# Show client statistics
SHOW CLIENTS;

# Show active queries
SHOW ACTIVE_SQL;
```

**Or check logs in real-time:**
```bash
# Monitor all 3 PgCat instances
docker logs -f pgcat_01 &
docker logs -f pgcat_02 &
docker logs -f pgcat_03 &
```

### 2. Monitor Database Connections

**Check active connections on primary:**
```bash
docker exec -it postgres_primary psql -U postgres -d postgres -c \
  "SELECT count(*) as total_connections, 
          count(*) FILTER (WHERE state = 'active') as active,
          count(*) FILTER (WHERE state = 'idle') as idle
   FROM pg_stat_activity 
   WHERE datname = 'postgres';"
```

**Check replication connections:**
```bash
docker exec -it postgres_primary psql -U postgres -d postgres -c \
  "SELECT application_name, state, sync_state, 
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as lag
   FROM pg_stat_replication;"
```

### 3. Monitor Replication Lag

**Check WAL positions:**
```bash
# On primary
docker exec -it postgres_primary psql -U postgres -d postgres -c \
  "SELECT pg_current_wal_lsn() as primary_lsn;"

# On each replica
for i in {1..5}; do
  echo "Replica $i:"
  docker exec -it postgres_replica_0$i psql -U postgres -d postgres -c \
    "SELECT pg_last_wal_replay_lsn() as replica_lsn;"
done
```

### 4. Monitor System Resources

**Check container resource usage:**
```bash
docker stats --no-stream postgres_primary postgres_replica_01 postgres_replica_02 \
  postgres_replica_03 postgres_replica_04 postgres_replica_05 \
  pgcat_01 pgcat_02 pgcat_03
```

**Monitor continuously:**
```bash
watch -n 1 'docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"'
```

### 5. Verify Data Distribution

**Check record count:**
```bash
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "SELECT COUNT(*) as total_records FROM test_table WHERE name LIKE 'stress_test_%';"
```

**Check data on primary:**
```bash
docker exec -it postgres_primary psql -U postgres -d postgres -c \
  "SELECT COUNT(*) FROM test_table WHERE name LIKE 'stress_test_%';"
```

**Check data on replicas (should match after replication):**
```bash
for i in {1..5}; do
  echo "Replica $i:"
  docker exec -it postgres_replica_0$i psql -U postgres -d postgres -c \
    "SELECT COUNT(*) FROM test_table WHERE name LIKE 'stress_test_%';"
done
```


## Verification Queries

### Check Write Routing (Should go to Primary)

```sql
-- This should succeed (routed to primary)
INSERT INTO test_table (name) VALUES ('routing_test_' || NOW()::text);

-- Verify it was inserted
SELECT * FROM test_table WHERE name LIKE 'routing_test_%' ORDER BY id DESC LIMIT 1;
```

### Check Read Routing (Should go to Replicas)

```sql
-- These should be routed to replicas
SELECT COUNT(*) FROM test_table;
SELECT * FROM test_table ORDER BY id DESC LIMIT 10;
```

### Check Replication Status

```sql
-- On primary - check replication connections
SELECT 
    application_name,
    state,
    sync_state,
    client_addr,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as replication_lag
FROM pg_stat_replication;
```

## Expected Results

### Successful Stress Test Should Show:

1. **All 200,000 records inserted** without errors
2. **Writes routed to primary** (check PgCat logs)
3. **Reads distributed across replicas** (check PgCat logs)
4. **Replication lag minimal** (< 1 second typically)
5. **All replicas have same data** after replication completes
6. **No connection errors** in PgCat logs
7. **Reasonable performance** (1,000+ records/second for inserts)

### Performance Benchmarks

Expected performance on typical hardware:
- **Insert rate:** 1,000 - 5,000 records/second
- **Replication lag:** < 1 second
- **Read queries:** < 10ms per query
- **Connection pool usage:** < 80% of pool_size
- **200,000 records:** Should complete in 40-200 seconds

## Troubleshooting

### Issue: Slow Insert Performance

**Check:**
- Primary database CPU/memory usage
- WAL disk I/O
- Connection pool exhaustion
- Network latency

**Solutions:**
- Increase `pool_size` in PgCat config
- Use batch inserts instead of individual inserts
- Check PostgreSQL `shared_buffers` and `work_mem` settings

### Issue: Replication Lag High

**Check:**
- Network between primary and replicas
- Replica disk I/O
- Number of replicas (more replicas = more WAL senders needed)

**Solutions:**
- Increase `max_wal_senders` on primary
- Check replica disk performance
- Reduce number of concurrent replicas if needed

### Issue: Connection Errors

**Check:**
- PgCat pool size limits
- Database connection limits
- Network connectivity

**Solutions:**
- Increase `pool_size` in PgCat config
- Check PostgreSQL `max_connections` setting
- Verify all containers are healthy

## Cleanup After Testing

**Remove test data:**
```bash
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "DELETE FROM test_table WHERE name LIKE 'stress_test_%';"
```

**Or truncate table (faster):**
```bash
psql -h localhost -p 6432 -U postgres -d postgres -c \
  "TRUNCATE TABLE test_table RESTART IDENTITY;"
```


## Notes

- **Batch size:** Default is 5,000 records per batch. Adjust `BATCH_SIZE` if you encounter memory issues.
- **Total records:** Set to 200,000. Change `TOTAL_RECORDS` to test with different volumes.
- **Monitor resources:** Watch CPU/memory usage during the test: `docker stats`
- **Replication:** Wait a few seconds after completion for replicas to catch up
- **Cleanup:** Use `TRUNCATE TABLE test_table RESTART IDENTITY;` to reset after testing

