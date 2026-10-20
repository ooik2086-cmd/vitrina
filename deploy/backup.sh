#!/bin/sh
# A copy of the database: dumped to /var/backups/vitrina (the last 7 days kept) and sent to the backup bucket
# (VITRINA_S3_BACKUP_BUCKET, the last 30 kept). setup.sh runs it every night (vitrina-backup.timer); it can be
# run by hand at any time. Photos are not in it: they live in the photos bucket.
#
#   sh deploy/backup.sh
#   systemctl list-timers vitrina-backup.timer; journalctl -u vitrina-backup   (when it last ran, what it said)
set -eu

cd "$(dirname "$0")"
DIR=${VITRINA_BACKUP_DIR:-/var/backups/vitrina}
C="docker compose ${VITRINA_COMPOSE_FILES:-}"

umask 077
mkdir -p "$DIR"
name=vitrina-$(date -u +%Y%m%dT%H%M%SZ).dump
# Custom format: compressed, and pg_restore can check it and restore it into an empty database.
$C exec -T db pg_dump -U vitrina -d vitrina -Fc > "$DIR/$name.part"
$C exec -T db pg_restore --list < "$DIR/$name.part" > /dev/null   # a dump cut short is not kept
mv "$DIR/$name.part" "$DIR/$name"
echo "dumped $DIR/$name ($(du -h "$DIR/$name" | cut -f1))"

backup() { $C run --rm --no-deps -T -u 0 -v "$DIR:/backups" api python -m vitrina_api.backup "$@"; }
backup put "/backups/$name"
backup prune --keep "${VITRINA_BACKUP_KEEP:-30}"

find "$DIR" -maxdepth 1 -name 'vitrina-*.dump' -mtime +"${VITRINA_BACKUP_KEEP_LOCAL:-7}" -delete
find "$DIR" -maxdepth 1 -name 'vitrina-*.part' -mmin +60 -delete
echo "backup done: $name"
