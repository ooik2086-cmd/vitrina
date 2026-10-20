#!/bin/sh
# A copy of the database: dumped to /var/backups/vitrina (the last 7 days kept) and sent to the backup bucket
# (VITRINA_S3_BACKUP_BUCKET, the last 30 kept). setup.sh runs it every night (vitrina-backup.timer); it can be
# run by hand at any time. Photos are not in it: they live in the photos bucket.
#
#   sh deploy/backup.sh
#   systemctl list-timers vitrina-backup.timer; journalctl -u vitrina-backup -n 30   (when it ran, what it said)
#
# deploy/backup.env (optional, root only, never given to the running services) may hold the backup bucket's own
# key (VITRINA_S3_BACKUP_ACCESS_KEY, VITRINA_S3_BACKUP_SECRET_KEY) and VITRINA_BACKUP_PING_URL: an address (for
# example a healthchecks.io check) that is called after every good backup, and at PING_URL/fail after a bad one,
# so a backup that stops working is noticed.
set -eu

cd "$(dirname "$0")"
DIR=${VITRINA_BACKUP_DIR:-/var/backups/vitrina}
C="docker compose ${VITRINA_COMPOSE_FILES:-}"
# shellcheck source=/dev/null
if [ -f backup.env ]; then set -a; . ./backup.env; set +a; fi
PING=${VITRINA_BACKUP_PING_URL:-}
ping_url() { [ -z "$PING" ] || curl -fsS -m 10 --retry 3 -o /dev/null "$1" || echo "could not reach $1"; }
trap 'if [ $? != 0 ]; then echo "BACKUP FAILED"; ping_url "$PING/fail"; fi' EXIT

umask 077
mkdir -p "$DIR"
# The random part keeps a copy from being found by its time alone.
name=vitrina-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n').dump
# Custom format: compressed, and pg_restore can check it and restore it into an empty database.
$C exec -T db pg_dump -U vitrina -d vitrina -Fc > "$DIR/$name.part"
# Read to the end (a table of contents alone also reads from a dump cut short): a broken dump is not kept.
$C exec -T db pg_restore -f /dev/null < "$DIR/$name.part"
mv "$DIR/$name.part" "$DIR/$name"
# pg_restore does not notice a few bytes missing at the end; the checksum does (restore.sh checks it).
(cd "$DIR" && sha256sum "$name" > "$name.sha256")
echo "dumped $DIR/$name ($(du -h "$DIR/$name" | cut -f1))"

backup() {
	$C run --rm --no-deps -T -u 0 -v "$DIR:/backups" \
		-e VITRINA_S3_BACKUP_ACCESS_KEY -e VITRINA_S3_BACKUP_SECRET_KEY api python -m vitrina_api.backup "$@"
}
backup put "/backups/$name"
backup prune --keep "${VITRINA_BACKUP_KEEP:-30}"

find "$DIR" -maxdepth 1 \( -name 'vitrina-*.dump' -o -name 'vitrina-*.dump.sha256' \) -mtime +"${VITRINA_BACKUP_KEEP_LOCAL:-7}" -delete
find "$DIR" -maxdepth 1 -name 'before-restore-*.dump' -mtime +30 -delete
find "$DIR" -maxdepth 1 -name 'vitrina-*.part' -mmin +60 -delete

# A full disk stops the database and the backups with it: said while there is still room.
used=$(df -P "$DIR" | awk 'NR == 2 { sub("%", "", $5); print $5 }')
if [ "$used" -ge "${VITRINA_DISK_ALARM:-90}" ]; then
	echo "the disk is $used% full: free space (docker image prune -f; docker builder prune -f) before it fills"
	exit 1
fi
ping_url "$PING"
echo "backup done: $name"
