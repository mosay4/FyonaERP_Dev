#!/bin/bash
# FYONA ERP — PITR Proof Test v6
# Fixes: 1) grab pg_wal from RUNNING container after changes
#        2) provide restore_command (required by PG 12+ with recovery.signal)
set -uo pipefail

PORT=5439; DB="fyona_test"; USER="testuser"; PASS="testpass123"
CONTAINER="fyona-pitr-test"; RESTORE_CONTAINER="fyona-pitr-restore"
BASE_DIR="/tmp/pitr_base"

cleanup() { docker rm -f "${CONTAINER}" "${RESTORE_CONTAINER}" 2>/dev/null; rm -rf /tmp/pitr_* 2>/dev/null; }
trap cleanup EXIT

echo "═══════════════════════════════════════════════════════════════"
echo "FYONA ERP — PITR Proof Test v6"
echo "═══════════════════════════════════════════════════════════════"
echo ""

rm -rf "${BASE_DIR}"; mkdir -p "${BASE_DIR}"

# ── STEP 1: Start PG with archive_mode ───────────────────────────────────────
echo "STEP 1: Starting PostgreSQL with archive_mode..."
docker run -d --name "${CONTAINER}" \
  -e POSTGRES_USER="${USER}" -e POSTGRES_PASSWORD="${PASS}" -e POSTGRES_DB="${DB}" \
  -p "${PORT}:5432" postgres:16-alpine 2>&1

for i in $(seq 1 30); do docker exec "${CONTAINER}" pg_isready -U "${USER}" >/dev/null 2>&1 && break; sleep 1; done

docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "ALTER SYSTEM SET wal_level = 'replica';"
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "ALTER SYSTEM SET max_wal_senders = '5';"
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "ALTER SYSTEM SET archive_mode = 'on';"
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "ALTER SYSTEM SET archive_command = 'cp %p /tmp/wal_archive_out/%f';"

docker stop "${CONTAINER}" >/dev/null 2>&1; sleep 3
docker start "${CONTAINER}" >/dev/null 2>&1; sleep 8
for i in $(seq 1 30); do docker exec "${CONTAINER}" pg_isready -U "${USER}" >/dev/null 2>&1 && break; sleep 1; done

AM=$(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SHOW archive_mode;" 2>/dev/null | tr -d '[:space:]')
WL=$(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SHOW wal_level;" 2>/dev/null | tr -d '[:space:]')
echo "  archive_mode: ${AM} | wal_level: ${WL}"
echo "  ✓ PostgreSQL ready"
echo ""

# ── STEP 2: Create data ──────────────────────────────────────────────────────
echo "STEP 2: Creating initial data..."
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "
CREATE TABLE pizzeria (id SERIAL PRIMARY KEY, name VARCHAR(100), created_at TIMESTAMP DEFAULT NOW());
INSERT INTO pizzeria (name) VALUES ('initial_1');
INSERT INTO pizzeria (name) VALUES ('initial_2');
"
echo "  ✓ Initial: $(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT count(*) FROM pizzeria;" | tr -d '[:space:]') rows"
echo ""

# ── STEP 3: Base backup ──────────────────────────────────────────────────────
echo "STEP 3: Taking base backup (T1)..."
T1=$(date '+%Y-%m-%d %H:%M:%S')
docker exec "${CONTAINER}" pg_basebackup -D /tmp/base -U "${USER}" -Ft -z -P -Xs 2>&1
docker cp "${CONTAINER}:/tmp/base/base.tar.gz" "${BASE_DIR}/base.tar.gz"
docker exec "${CONTAINER}" rm -rf /tmp/base
echo "  T1: ${T1} | $(du -sh ${BASE_DIR}/base.tar.gz | awk '{print $1}')"
echo ""

# ── STEP 4-6: Changes ───────────────────────────────────────────────────────
echo "STEP 4: Change #1..."
sleep 5
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "INSERT INTO pizzeria (name) VALUES ('change_1') RETURNING created_at;" | grep -v "^$" | tail -1
# Capture the EXACT commit time from PostgreSQL server
T2=$(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT to_char(created_at, 'YYYY-MM-DD HH24:MI:SS.MS') FROM pizzeria WHERE name='change_1';" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
# Add +1 second to ensure we capture AFTER the commit
T2_RECOVER=$(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT to_char(created_at + interval '1 second', 'YYYY-MM-DD HH24:MI:SS.MS') FROM pizzeria WHERE name='change_1';" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "SELECT pg_switch_wal();" >/dev/null 2>&1
sleep 3
echo "  T2 commit: ${T2} | T2 recover target: ${T2_RECOVER} | rows: $(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT count(*) FROM pizzeria;" | tr -d '[:space:]')"

echo "STEP 5: Change #2..."
sleep 5
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "INSERT INTO pizzeria (name) VALUES ('change_2') RETURNING created_at;" | grep -v "^$" | tail -1
T3=$(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT to_char(created_at, 'YYYY-MM-DD HH24:MI:SS.MS') FROM pizzeria WHERE name='change_2';" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
T3_RECOVER=$(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT to_char(created_at + interval '1 second', 'YYYY-MM-DD HH24:MI:SS.MS') FROM pizzeria WHERE name='change_2';" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "SELECT pg_switch_wal();" >/dev/null 2>&1
sleep 3
echo "  T3 commit: ${T3} | T3 recover target: ${T3_RECOVER} | rows: $(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT count(*) FROM pizzeria;" | tr -d '[:space:]')"

echo "STEP 6: Change #3 (should be LOST)..."
sleep 5
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "INSERT INTO pizzeria (name) VALUES ('change_3') RETURNING created_at;" | grep -v "^$" | tail -1
T4=$(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT to_char(created_at, 'YYYY-MM-DD HH24:MI:SS.MS') FROM pizzeria WHERE name='change_3';" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "SELECT pg_switch_wal();" >/dev/null 2>&1
sleep 3
echo "  T4 commit: ${T4} | rows: $(docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT count(*) FROM pizzeria;" | tr -d '[:space:]')"
echo ""

# ── STEP 7: Grab pg_wal + archived WAL from RUNNING source ──────────────────
echo "STEP 7: Grabbing pg_wal from running source container (includes all changes)..."
docker stop "${CONTAINER}" >/dev/null 2>&1; sleep 2
# Get host data dir of the source container
SRC_DATA=$(docker inspect "${CONTAINER}" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
echo "  Source data dir: ${SRC_DATA}"
# Copy pg_wal directly from host
cp -r "${SRC_DATA}/pg_wal" "${BASE_DIR}/pg_wal_full"
WAL_SEGMENTS=$(ls "${BASE_DIR}/pg_wal_full"/0* 2>/dev/null | wc -l)
echo "  pg_wal segments: ${WAL_SEGMENTS}"
ls "${BASE_DIR}/pg_wal_full"/0* 2>/dev/null | while read f; do echo "    $(basename $f) ($(stat -c%s "$f" 2>/dev/null || echo '?') bytes)"; done

# Also grab any archived WAL
mkdir -p "${BASE_DIR}/archived_wal"
docker start "${CONTAINER}" >/dev/null 2>&1; sleep 3
docker exec "${CONTAINER}" bash -c "cp /tmp/wal_archive_out/* /tmp/wal_export/ 2>/dev/null; mkdir -p /tmp/wal_export; cp /tmp/wal_archive_out/* /tmp/wal_export/ 2>/dev/null" 2>/dev/null
ARCHIVED_WAL_COUNT=$(docker exec "${CONTAINER}" bash -c "ls /tmp/wal_archive_out/ 2>/dev/null | wc -l" 2>/dev/null || echo "0")
echo "  Archived WAL (inside container): ${ARCHIVED_WAL_COUNT}"
echo ""

# ── STEP 8: PITR to T2 ──────────────────────────────────────────────────────
echo "STEP 8: PITR RESTORE to T2 (${T2}) — expect 3 rows..."
echo "  Expected: 3 rows (initial_1, initial_2, change_1)"

docker rm -f "${RESTORE_CONTAINER}" 2>/dev/null
docker run -d --name "${RESTORE_CONTAINER}" \
  -e POSTGRES_USER="${USER}" -e POSTGRES_PASSWORD="${PASS}" -e POSTGRES_DB="${DB}" \
  -p 5440:5432 postgres:16-alpine 2>&1
sleep 5
for i in $(seq 1 30); do docker exec "${RESTORE_CONTAINER}" pg_isready -U "${USER}" >/dev/null 2>&1 && break; sleep 1; done

docker stop "${RESTORE_CONTAINER}" >/dev/null 2>&1; sleep 2
HOST_DATA=$(docker inspect "${RESTORE_CONTAINER}" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)

# Replace with base backup
rm -rf "${HOST_DATA:?}"/*
tar -xzf "${BASE_DIR}/base.tar.gz" -C "${HOST_DATA}/" 2>/dev/null

# Overlay FULL pg_wal (includes all changes from source)
rm -rf "${HOST_DATA}/pg_wal"
cp -r "${BASE_DIR}/pg_wal_full" "${HOST_DATA}/pg_wal"

# recovery.signal + postgresql.auto.conf
touch "${HOST_DATA}/recovery.signal"
cat > "${HOST_DATA}/postgresql.auto.conf" << EOF
restore_command = 'exit 1'
recovery_target_time = '${T2_RECOVER}'
recovery_target_action = 'promote'
EOF

echo "  recovery.signal: exists"
echo "  pg_wal segments: $(ls ${HOST_DATA}/pg_wal/0* 2>/dev/null | wc -l)"
echo "  recovery target: ${T2_RECOVER} (after change_1 commit at ${T2})"
cat "${HOST_DATA}/postgresql.auto.conf"

chown -R 999:999 "${HOST_DATA}" 2>/dev/null || true

docker start "${RESTORE_CONTAINER}" >/dev/null 2>&1
echo "  Waiting for recovery..."

for i in $(seq 1 60); do
    sleep 1
    IS_READY=$(docker exec "${RESTORE_CONTAINER}" pg_isready -U "${USER}" 2>/dev/null | grep -c "accepting connections" || true)
    if [ "${IS_READY}" -gt 0 ]; then echo "  ✓ PG ready after ${i}s"; break; fi
done

# Show relevant logs
echo "  === Recovery logs ==="
docker logs "${RESTORE_CONTAINER}" 2>&1 | grep -E "recovery|restore|promote|FATAL|ERROR|LOG:.*starting" | tail -20
echo "  === end ==="

IN_RECOVERY=$(docker exec "${RESTORE_CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]')
PITR_T2_COUNT=$(docker exec "${RESTORE_CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT count(*) FROM pizzeria;" 2>/dev/null | tr -d '[:space:]')
PITR_T2_ROWS=$(docker exec "${RESTORE_CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT name FROM pizzeria ORDER BY id;" 2>/dev/null)

echo ""
echo "  ═══════════════════════════════════════"
echo "  PITR RESULT (target: T2 = ${T2_RECOVER})"
echo "  ═══════════════════════════════════════"
echo "  pg_is_in_recovery: [${IN_RECOVERY:-?}]"
echo "  Expected: 3 rows (initial_1, initial_2, change_1)"
echo "  Actual:   [${PITR_T2_COUNT:-FAILED}] rows"
echo "  Data:     [${PITR_T2_ROWS:-FAILED}]"

PITR_T2_PASS="FAIL"
if [ "${PITR_T2_COUNT:-0}" -eq 3 ] 2>/dev/null; then
    if echo "${PITR_T2_ROWS}" | grep -q "change_1" && \
       ! echo "${PITR_T2_ROWS}" | grep -q "change_2" && \
       ! echo "${PITR_T2_ROWS}" | grep -q "change_3"; then
        PITR_T2_PASS="PASS"
        echo "  ✅ PITR TO T2: SUCCESS"
    fi
fi
[ "${PITR_T2_PASS}" = "FAIL" ] && echo "  ❌ PITR TO T2: FAIL"
echo ""

# ── STEP 9: PITR to T3 ──────────────────────────────────────────────────────
echo "STEP 9: PITR RESTORE to T3 (${T3}) — expect 4 rows..."
echo "  Expected: 4 rows (initial_1, initial_2, change_1, change_2)"

docker stop "${RESTORE_CONTAINER}" >/dev/null 2>&1; sleep 2
rm -rf "${HOST_DATA:?}"/*
tar -xzf "${BASE_DIR}/base.tar.gz" -C "${HOST_DATA}/" 2>/dev/null
rm -rf "${HOST_DATA}/pg_wal"
cp -r "${BASE_DIR}/pg_wal_full" "${HOST_DATA}/pg_wal"
touch "${HOST_DATA}/recovery.signal"
cat > "${HOST_DATA}/postgresql.auto.conf" << EOF
restore_command = 'exit 1'
recovery_target_time = '${T3_RECOVER}'
recovery_target_action = 'promote'
EOF
chown -R 999:999 "${HOST_DATA}" 2>/dev/null || true
docker start "${RESTORE_CONTAINER}" >/dev/null 2>&1

for i in $(seq 1 60); do
    sleep 1
    IS_READY=$(docker exec "${RESTORE_CONTAINER}" pg_isready -U "${USER}" 2>/dev/null | grep -c "accepting connections" || true)
    if [ "${IS_READY}" -gt 0 ]; then echo "  ✓ PG ready after ${i}s"; break; fi
done

echo "  === Recovery logs ==="
docker logs "${RESTORE_CONTAINER}" 2>&1 | grep -E "recovery|restore|promote|FATAL|ERROR|LOG:.*starting" | tail -10
echo "  === end ==="

PITR_T3_COUNT=$(docker exec "${RESTORE_CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT count(*) FROM pizzeria;" 2>/dev/null | tr -d '[:space:]')
PITR_T3_ROWS=$(docker exec "${RESTORE_CONTAINER}" psql -U "${USER}" -d "${DB}" -tAc "SELECT name FROM pizzeria ORDER BY id;" 2>/dev/null)

echo ""
echo "  ═══════════════════════════════════════"
echo "  PITR RESULT (target: T3 = ${T3_RECOVER})"
echo "  ═══════════════════════════════════════"
echo "  Expected: 4 rows (no change_3)"
echo "  Actual:   [${PITR_T3_COUNT:-FAILED}] rows"
echo "  Data:     [${PITR_T3_ROWS:-FAILED}]"

PITR_T3_PASS="FAIL"
if [ "${PITR_T3_COUNT:-0}" -eq 4 ] 2>/dev/null; then
    if echo "${PITR_T3_ROWS}" | grep -q "change_2" && \
       ! echo "${PITR_T3_ROWS}" | grep -q "change_3"; then
        PITR_T3_PASS="PASS"
        echo "  ✅ PITR TO T3: SUCCESS"
    fi
fi
[ "${PITR_T3_PASS}" = "FAIL" ] && echo "  ❌ PITR TO T3: FAIL"
echo ""

# ── SUMMARY ──────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════"
echo "PITR TEST RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo "archive_mode: ${AM:-?}"
echo "T1 (base): ${T1}"
echo "T2 (c1 commit):   ${T2} (recover to: ${T2_RECOVER})"
echo "T3 (c2 commit):   ${T3} (recover to: ${T3_RECOVER})"
echo "T4 (c3):   ${T4}"
echo "pg_wal segments: ${WAL_SEGMENTS}"
echo ""
echo "PITR to T2: ${PITR_T2_COUNT:-?} rows — ${PITR_T2_PASS}"
echo "PITR to T3: ${PITR_T3_COUNT:-?} rows — ${PITR_T3_PASS}"
echo ""
if [ "${PITR_T2_PASS}" = "PASS" ] && [ "${PITR_T3_PASS}" = "PASS" ]; then
    echo "OVERALL: ✅ PITR PROOF TEST PASSED"
else
    echo "OVERALL: ❌ PITR PROOF TEST FAILED"
fi
echo "═══════════════════════════════════════════════════════════════"
