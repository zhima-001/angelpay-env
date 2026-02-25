#!/bin/bash
set -e

NAMESPACE=${1:-angelpay-staging}
BACKUP_FILE=${2}

if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: ./restore.sh <namespace> <backup_file>"
  exit 1
fi

DB_POD=$(kubectl get pods -n "$NAMESPACE" -l app=mysql -o jsonpath='{.items[0].metadata.name}')

echo "Restoring MySQL database to pod $DB_POD in namespace $NAMESPACE from $BACKUP_FILE..."
cat "$BACKUP_FILE" | kubectl exec -i -n "$NAMESPACE" "$DB_POD" -- bash -c 'mysql -u$MYSQL_USER -p$MYSQL_PASSWORD $MYSQL_DATABASE'

echo "Restore completed successfully!"
