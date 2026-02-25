#!/bin/bash
set -e

NAMESPACE=${1:-angelpay-staging}
BACKUP_DIR="backups"
DATE=$(date +"%Y%m%d_%H%M%S")
DB_POD=$(kubectl get pods -n "$NAMESPACE" -l app=mysql -o jsonpath='{.items[0].metadata.name}')

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/db_${NAMESPACE}_${DATE}.sql"

echo "Backing up MySQL database from pod $DB_POD in namespace $NAMESPACE..."
kubectl exec -n "$NAMESPACE" "$DB_POD" -- bash -c 'mysqldump -u$MYSQL_USER -p$MYSQL_PASSWORD $MYSQL_DATABASE' > "$BACKUP_FILE"

echo "Backup completed successfully! Saved to $BACKUP_FILE"
