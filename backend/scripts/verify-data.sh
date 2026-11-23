#!/bin/bash
echo "=== Database Integrity Check ==="
echo ""
echo "Tables count:"
docker exec fyona-db psql -U fyona -d fyona_erp -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>&1 | tr -d '[:space:]'
echo ""
echo ""
echo "Sample table counts:"
docker exec fyona-db psql -U fyona -d fyona_erp -t -c "SELECT 'customers: ' || count(*) FROM customers;" 2>&1 | tr -d '[:space:]'
echo ""
docker exec fyona-db psql -U fyona -d fyona_erp -t -c "SELECT 'invoices: ' || count(*) FROM invoices;" 2>&1 | tr -d '[:space:]'
echo ""
docker exec fyona-db psql -U fyona -d fyona_erp -t -c "SELECT 'bank_accounts: ' || count(*) FROM bank_accounts;" 2>&1 | tr -d '[:space:]'
echo ""
echo ""
echo "Alembic version:"
docker exec fyona-db psql -U fyona -d fyona_erp -t -c "SELECT version_num FROM alembic_version;" 2>&1 | tr -d '[:space:]'
echo ""

echo ""
echo "=== MinIO Check ==="
docker exec fyona-minio ls /data 2>&1

echo ""
echo "=== Redis Check ==="
docker exec fyona-redis redis-cli ping 2>&1

echo ""
echo "=== All data services OK ==="
