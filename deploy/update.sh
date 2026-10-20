#!/bin/sh
# Installs the newest code of the branch: a backup first, then the new image is built while the old one keeps
# serving, the photo worker and the jobs are stopped while the API brings the database to the new schema, and the
# images left over are removed (each build would otherwise keep ~200 MB on the disk).
#
#   sh /opt/vitrina/deploy/update.sh
#
# If the new version does not come up, it prints how to go back to the previous image and the database as it was.
set -eu

cd "$(dirname "$0")"
C="docker compose ${VITRINA_COMPOSE_FILES:-}"

[ -n "${VITRINA_NO_PULL:-}" ] || git -C .. pull --ff-only
sh ./backup.sh
# shellcheck disable=SC2012  # names without spaces, made by backup.sh
dump=$(ls -t "${VITRINA_BACKUP_DIR:-/var/backups/vitrina}"/vitrina-*.dump | head -n 1)
docker image inspect vitrina-api > /dev/null 2>&1 && docker tag vitrina-api vitrina-api:prev
[ -n "${VITRINA_NO_BUILD:-}" ] || $C build

trap 'if [ $? != 0 ]; then cat >&2 <<EOF
UPDATE FAILED. The log above (and: docker compose logs --tail 100 api) says why. To go back:
  docker tag vitrina-api:prev vitrina-api && $C up -d --no-build --wait
  sh $PWD/restore.sh $dump --yes     (only if the new version changed the database)
EOF
fi' EXIT
$C stop photos jobs
$C up -d --no-build --wait --wait-timeout 600
trap - EXIT
docker image prune -f > /dev/null
docker builder prune -f --filter until=168h > /dev/null
$C ps
echo "updated to $(git -C .. log -1 --format='%h %s')"
