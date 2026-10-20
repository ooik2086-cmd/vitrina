#!/bin/sh
# A copy of the database: dumped to /var/backups/vitrina (the last 7 days kept) and sent to the backup bucket
# (VITRINA_S3_BACKUP_BUCKET, the last 30 kept). setup.sh runs it every night (vitrina-backup.timer); it can be
# run by hand at any time. With VITRINA_STORAGE=s3 the photos are in their bucket, not here. With
# VITRINA_STORAGE=disk the photos and private files are copied to /var/backups/vitrina/files too, and the backup
# bucket is optional: without it nothing leaves the server unless that folder is copied off it (deploy/README.md).
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
setting() { sed -n "s/^$1=//p" .env | tail -n 1; }
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
# The dump leaves the server first: whatever goes wrong with the files below, tonight's database copy is out.
if [ -n "$(setting VITRINA_S3_BACKUP_BUCKET)" ]; then
	backup put "/backups/$name"
	backup prune --keep "${VITRINA_BACKUP_KEEP:-30}"
else
	echo "no backup bucket (VITRINA_S3_BACKUP_BUCKET): the copies are on this server only; copy $DIR off it (deploy/README.md)"
fi
files_failed=
if [ "$(setting VITRINA_STORAGE)" = disk ]; then
	# The folders as they are now, through the API's image, which has the volumes mounted; owned and readable by
	# root only, like the dumps. A file gone from a volume is moved to files/removed/DATE and kept there 30 days.
	day=$(date -u +%Y%m%d)
	$C run --rm --no-deps -T -u 0 -v "$DIR/files:/copy" api nice -n 10 sh -c \
		"python -m vitrina_api.backup mirror /data/media /copy/media --removed-to /copy/removed/$day/media &&
		 python -m vitrina_api.backup mirror /data/private /copy/private --removed-to /copy/removed/$day/private" ||
		files_failed=1
	chmod 700 "$DIR/files"
	find "$DIR/files/removed" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2> /dev/null || true
fi

find "$DIR" -maxdepth 1 \( -name 'vitrina-*.dump' -o -name 'vitrina-*.dump.sha256' \) -mtime +"${VITRINA_BACKUP_KEEP_LOCAL:-7}" -delete
find "$DIR" -maxdepth 1 -name 'before-restore-*.dump' -mtime +30 -delete
find "$DIR" -maxdepth 1 -name 'vitrina-*.part' -mmin +60 -delete

# A full disk stops the database and the backups with it: said while there is still room.
used=$(df -P "$DIR" | awk 'NR == 2 { sub("%", "", $5); print $5 }')
if [ "$used" -ge "${VITRINA_DISK_ALARM:-90}" ]; then
	echo "the disk is $used% full: free space (docker image prune -f; docker builder prune -f) before it fills"
	exit 1
fi
if [ -n "$files_failed" ]; then
	echo "the database is backed up ($name), but copying the photos and private files failed (said above)"
	exit 1
fi
ping_url "$PING"
echo "backup done: $name"
