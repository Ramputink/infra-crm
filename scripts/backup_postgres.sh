#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


DATE=$(date +%F)
BACKUP_DIR="/opt/backups"

# variables (ajusta si cambiaste nombres)
POSTGRES_CONTAINER="compose-postgres-1"
POSTGRES_DB="n8n"
POSTGRES_USER="postgres"

mkdir -p $BACKUP_DIR

docker exec -t $POSTGRES_CONTAINER \
  pg_dump -U $POSTGRES_USER $POSTGRES_DB \
  > $BACKUP_DIR/db_$DATE.sql

echo "Backup created: $BACKUP_DIR/db_$DATE.sql"

