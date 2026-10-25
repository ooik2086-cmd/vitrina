#!/bin/sh
# Installs the newest code of the branch: a backup first, then the new image is built while the old one keeps
# serving, the photo worker and the jobs are stopped while the API brings the database to the new schema, and the
# images left over are removed (each build would otherwise keep ~200 MB on the disk).
#
#   sh /opt/vitrina/deploy/update.sh
#
# If .env lacks a setting the new version needs, it is added there and the script stops (exit 2) until it is filled.
# If the new version does not come up, it prints how to go back to the previous image and the database as it was.
set -eu

cd "$(dirname "$0")"
C="docker compose ${VITRINA_COMPOSE_FILES:-}"

[ -n "${VITRINA_NO_PULL:-}" ] || git -C .. pull --ff-only
# A new version may need new settings: they are added to .env and, while one is empty, nothing is touched yet.
DEPLOY=$PWD
# shellcheck disable=SC2034  # read by env.sh
ENV_FILE="$DEPLOY/.env"
# shellcheck disable=SC1091  # deploy/env.sh
. ./env.sh
need_filled
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
# Removed, not only stopped: a container that has just stopped can still read as "exited" to the --wait below,
# which then fails the update although nothing is wrong (seen in CI). Named volumes are kept.
$C rm --stop --force photos push jobs
$C up -d --no-build --wait --wait-timeout 600
trap - EXIT
docker image prune -f > /dev/null
docker builder prune -f --filter until=168h > /dev/null
$C ps
echo "updated to $(git -C .. log -1 --format='%h %s')"
