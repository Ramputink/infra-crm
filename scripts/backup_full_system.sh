#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DATE=$(date +%F)
BACKUP_DIR="/opt/system_backups"
SOURCE_DIR="/opt/automatizacion_crm"

mkdir -p $BACKUP_DIR

echo "Stopping containers..."
docker compose -f /opt/automatizacion_crm/compose/docker-compose.yml down

echo "Creating backup..."
tar -czf $BACKUP_DIR/automatizacion_crm_$DATE.tar.gz $SOURCE_DIR

echo "Starting containers..."
docker compose -f /opt/automatizacion_crm/compose/docker-compose.yml up -d

echo "Backup completed: $BACKUP_DIR/automatizacion_crm_$DATE.tar.gz"
# eliminar backups con más de 90 días (3 meses)
find $BACKUP_DIR -type f -mtime +90 -delete
