#!/bin/sh
# Puts a backup back in place of the current database. The API, the photo worker and the jobs are stopped
# meanwhile (the site answers 502 for a minute or two), and the current database is dumped first, so a restore
# can itself be undone.
#
#   sh deploy/restore.sh /var/backups/vitrina/vitrina-20261020T213000Z-3f9a0c1d.dump --yes
#   sh deploy/restore.sh --from-bucket vitrina-20261020T213000Z-3f9a0c1d.dump --yes   (from the backup bucket)
#   sh deploy/restore.sh --files --yes   (VITRINA_STORAGE=disk: photos and private files back from the nightly copy;
#                                         files added since are kept)
#   docker compose -f deploy/compose.yml run --rm --no-deps api python -m vitrina_api.backup list
set -eu

usage="usage: restore.sh FILE.dump --yes  |  restore.sh --from-bucket NAME --yes  |  restore.sh --files --yes"
[ "${2:-}" = "--yes" ] || [ "${3:-}" = "--yes" ] || { echo "$usage"; echo "It replaces the whole database: add --yes."; exit 1; }
case $1 in
	--from-bucket | --files | /*) ;;
	*) set -- "$PWD/$1" "$2" "${3:-}" ;;   # a path given from where the operator stands
esac

cd "$(dirname "$0")"
DIR=${VITRINA_BACKUP_DIR:-/var/backups/vitrina}
C="docker compose ${VITRINA_COMPOSE_FILES:-}"
# shellcheck source=/dev/null
if [ -f backup.env ]; then set -a; . ./backup.env; set +a; fi
umask 077
mkdir -p "$DIR"
if [ "$1" = "--files" ]; then
	[ -d "$DIR/files/media" ] && [ -d "$DIR/files/private" ] || { echo "no copy of the files in $DIR/files"; exit 1; }
	$C run --rm --no-deps -T -u 0 -v "$DIR/files:/copy:ro" api sh -c \
		'python -m vitrina_api.backup mirror --keep-extra /copy/media /data/media && python -m vitrina_api.backup mirror --keep-extra /copy/private /data/private && chown -R vitrina /data/media /data/private'
	echo "files put back from $DIR/files"
	exit 0
fi
if [ "$1" = "--from-bucket" ]; then
	$C run --rm --no-deps -T -u 0 -v "$DIR:/backups" -e VITRINA_S3_BACKUP_ACCESS_KEY -e VITRINA_S3_BACKUP_SECRET_KEY \
		api python -m vitrina_api.backup get "$2" /backups/
	file="$DIR/$2"
else
	file=$1
fi
[ -s "$file" ] || { echo "no such backup: $file"; exit 1; }
if [ -f "$file.sha256" ]; then
	(cd "$(dirname "$file")" && sha256sum -c --quiet "$(basename "$file").sha256") ||
		{ echo "$file does not match its checksum (cut short or changed): nothing was changed"; exit 1; }
else
	echo "no $file.sha256 beside it: only checking that the dump reads to the end"
fi
# Read to the end before anything is touched: a dump cut short fails here, with the database still in place.
$C exec -T db pg_restore -f /dev/null < "$file" || { echo "$file is not a whole dump: nothing was changed"; exit 1; }

before="$DIR/before-restore-$(date -u +%Y%m%dT%H%M%SZ).dump"
$C exec -T db pg_dump -U vitrina -d vitrina -Fc > "$before"
echo "the current database is saved in $before"

trap 'if [ $? != 0 ]; then echo "RESTORE FAILED: the API is stopped. To go back to the database as it was: sh $PWD/restore.sh $before --yes" >&2; fi' EXIT
$C stop api photos jobs
$C exec -T db dropdb -U vitrina --force vitrina
$C exec -T db createdb -U vitrina -O vitrina vitrina
$C exec -T db pg_restore -U vitrina -d vitrina --no-owner --exit-on-error < "$file"
# The API brings an older copy up to the current schema (alembic upgrade head) as it starts.
$C up -d --wait --wait-timeout 600
trap - EXIT
echo "restored $file"
