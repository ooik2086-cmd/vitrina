#!/bin/sh
# Puts a backup back in place of the current database. The API, the photo worker and the jobs are stopped
# meanwhile (the site answers 502 for a minute or two), and the current database is dumped first, so a restore
# can itself be undone.
#
#   sh deploy/restore.sh /var/backups/vitrina/vitrina-20261020T213000Z.dump --yes
#   sh deploy/restore.sh --from-bucket vitrina-20261020T213000Z.dump --yes   (a copy from the backup bucket)
#   docker compose -f deploy/compose.yml run --rm --no-deps api python -m vitrina_api.backup list
set -eu

cd "$(dirname "$0")"
DIR=${VITRINA_BACKUP_DIR:-/var/backups/vitrina}
C="docker compose ${VITRINA_COMPOSE_FILES:-}"
usage="usage: restore.sh FILE.dump --yes  |  restore.sh --from-bucket NAME --yes"

[ "${2:-}" = "--yes" ] || [ "${3:-}" = "--yes" ] || { echo "$usage"; echo "It replaces the whole database: add --yes."; exit 1; }
umask 077
mkdir -p "$DIR"
if [ "$1" = "--from-bucket" ]; then
	$C run --rm --no-deps -T -u 0 -v "$DIR:/backups" api python -m vitrina_api.backup get "$2" /backups/
	file="$DIR/$2"
else
	file=$1
fi
[ -s "$file" ] || { echo "no such backup: $file"; exit 1; }
$C exec -T db pg_restore --list < "$file" > /dev/null || { echo "$file is not a usable dump"; exit 1; }

before="$DIR/before-restore-$(date -u +%Y%m%dT%H%M%SZ).dump"
$C exec -T db pg_dump -U vitrina -d vitrina -Fc > "$before"
echo "the current database is saved in $before"

$C stop api photos jobs
$C exec -T db dropdb -U vitrina --force vitrina
$C exec -T db createdb -U vitrina -O vitrina vitrina
$C exec -T db pg_restore -U vitrina -d vitrina --no-owner --exit-on-error < "$file"
# The API brings an older copy up to the current schema (alembic upgrade head) as it starts.
$C up -d --wait --wait-timeout 600
echo "restored $file"
