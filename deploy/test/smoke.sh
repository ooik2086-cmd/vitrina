#!/bin/sh
# shellcheck disable=SC2012  # file names here are made by the scripts: no spaces
# Starts the real deploy/compose.yml (with a stand-in S3 and a throwaway certificate) and walks through what the
# server must do: HTTPS and the redirect to it, nothing but Caddy reachable, a seller listing a shoe with photos
# (stored in the bucket, cut out by the photo worker), the share page's https address, the production check, and
# a nightly backup restored from the bucket, a cut-short dump refused, and an update. CI runs it as root on its
# Ubuntu machine with SMOKE_SETUP=1, which also runs setup.sh itself (packages, firewall, time zone, the backup
# timer). Locally: sh deploy/test/smoke.sh (needs ports 80, 443); SMOKE_BUILD=--no-build reuses an image named
# vitrina-api.
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
cp -r "$REPO/deploy" "$T/deploy"
ln -s "$REPO/backend" "$T/backend"
cd "$T/deploy"
export COMPOSE_PROJECT_NAME=vitrina-smoke VITRINA_BACKUP_DIR="$T/backups"
export VITRINA_COMPOSE_FILES="-f compose.yml -f test/compose.test.yml"
C="docker compose $VITRINA_COMPOSE_FILES"
cleanup() {
	status=$?
	if [ "$status" != 0 ]; then $C ps -a || true; $C logs --tail 40 || true; fi
	$C down -v --remove-orphans > /dev/null 2>&1 || true
	rm -rf "$T"
	exit "$status"
}
trap cleanup EXIT
step() { printf '\n== %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
https() { curl -fsS --noproxy "*" --cacert test/certs/ca.pem --resolve vitrina.test:443:127.0.0.1 "$@"; }
flow() { $C exec -T api python - "$@" < test/flow.py; }

step "a certificate for vitrina.test and s3.test from a throwaway authority"
mkdir -p test/certs && cd test/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=smoke CA" -keyout ca.key -out ca.pem 2> /dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=vitrina.test" -keyout site.key -out site.csr 2> /dev/null
printf 'subjectAltName=DNS:vitrina.test,DNS:s3.test\n' > san.ext
openssl x509 -req -in site.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile san.ext -out site.pem 2> /dev/null
chmod 644 ./*
cd ../..

step "setup.sh writes .env once, with new secrets"
sh setup.sh --env-only vitrina.test smoke@example.kz
first=$(cat .env)
if sh setup.sh --env-only other.test other@example.kz; then fail "setup.sh took another domain silently"; fi
[ "$(cat .env)" = "$first" ] || fail "setup.sh overwrote an existing .env"
sh setup.sh --env-only vitrina.test smoke@example.kz > /dev/null || fail "setup.sh refused its own domain again"
[ "$(stat -c %a .env)" = 600 ] || fail ".env is readable by others"
secrets=$(grep -E '^(POSTGRES_PASSWORD|VITRINA_(OTP|PAYMENT|DELIVERY)_SECRET)=' .env | cut -d= -f2)
[ "$(echo "$secrets" | grep -cE '^[0-9a-f]{64}$')" = 4 ] || fail "secrets are not 64 random hex digits"
[ "$(echo "$secrets" | sort -u | wc -l)" = 4 ] || fail "two secrets are the same"
grep -q '^VITRINA_CORS_ORIGINS=https://vitrina.test$' .env || fail "CORS origin not set to the site"
if [ -n "${SMOKE_SETUP:-}" ]; then
	step "setup.sh on this Ubuntu machine stops until the storage lines are filled"
	status=0
	VITRINA_BUILD="${SMOKE_BUILD:---build}" sh setup.sh || status=$?
	[ "$status" = 2 ] || fail "setup.sh did not stop for the unfilled S3 lines (exit $status)"
fi
sed -i -e 's|^VITRINA_TLS=.*|VITRINA_TLS=/certs/site.pem /certs/site.key|' \
	-e 's|^VITRINA_S3_ENDPOINT=.*|VITRINA_S3_ENDPOINT=https://s3.test|' \
	-e 's|^VITRINA_S3_ACCESS_KEY=.*|VITRINA_S3_ACCESS_KEY=smoke|' \
	-e 's|^VITRINA_S3_SECRET_KEY=.*|VITRINA_S3_SECRET_KEY=smoke-secret|' \
	-e 's|^VITRINA_PUBLIC_MEDIA_URL=.*|VITRINA_PUBLIC_MEDIA_URL=https://s3.test/vitrina-photos|' .env

if [ -n "${SMOKE_SETUP:-}" ]; then
	step "setup.sh again: starts, checks the buckets, makes the first backup, installs the timer"
	VITRINA_BUILD="${SMOKE_BUILD:---build}" sh setup.sh
	systemctl is-enabled vitrina-backup.timer | grep -qx enabled || fail "the backup timer is not enabled"
	systemd-analyze verify /etc/systemd/system/vitrina-backup.service /etc/systemd/system/vitrina-backup.timer
	[ "$(timedatectl show -p Timezone --value)" = Asia/Almaty ] || fail "the time zone is not Asia/Almaty"
	ufw status | grep -q 'Status: active' || fail "the firewall is off"
	n=$(ls "$VITRINA_BACKUP_DIR"/vitrina-*.dump | wc -l)
	systemctl start vitrina-backup.service || { journalctl -u vitrina-backup -n 40 --no-pager; fail "the nightly backup unit failed"; }
	[ "$(ls "$VITRINA_BACKUP_DIR"/vitrina-*.dump | wc -l)" -gt "$n" ] || fail "the backup unit made no new dump"
else
	step "start (production mode: the API refuses unsafe settings)"
	$C up -d "${SMOKE_BUILD:---build}" --wait --wait-timeout 900
	$C ps
	step "the three buckets: photos public, the other two closed"
	$C run --rm --no-deps -T api python -m vitrina_api.backup check
fi
[ "$(docker inspect -f '{{.State.Health.Status}}' vitrina-smoke-jobs-1)" = healthy ] || fail "the jobs have not run"

step "HTTPS, and plain http sent to it"
[ "$(https https://vitrina.test/api/v1/health)" = '{"ok":true}' ] || fail "health over https"
https -o /dev/null -D - https://vitrina.test/api/v1/health | grep -qi '^strict-transport-security: max-age=31536000' || fail "no HSTS"
redirect=$(curl -sS --noproxy "*" -o /dev/null -w '%{http_code} %{redirect_url}' --resolve vitrina.test:80:127.0.0.1 http://vitrina.test/admin/)
[ "$redirect" = "308 https://vitrina.test/admin/" ] || fail "http is not redirected to https: $redirect"

step "only Caddy is reachable from outside"
published=$(docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" --format '{{.Names}} {{.Ports}}' | grep -- '->' || true)
echo "$published"
[ "$(echo "$published" | grep -v '^vitrina-smoke-caddy-1 ' | grep -c .)" = 0 ] || fail "more than Caddy is published"
curl -fsS --noproxy "*" --max-time 3 http://127.0.0.1:8000/api/v1/health > /dev/null 2>&1 && fail "the API answers on port 8000"

step "a seller lists a shoe: photos in the bucket, cut out by the photo worker"
first_id=$(flow list)
flow check "$first_id"

step "production check: the API does not start without the backup bucket"
if out=$($C run --rm --no-deps -T -e VITRINA_S3_BACKUP_BUCKET= api python -c \
	'from vitrina_api.app import create_app; create_app()' 2>&1); then fail "the API started without a backup bucket"; fi
echo "$out" | grep -q VITRINA_S3_BACKUP_BUCKET || fail "the refusal does not name the setting: $out"

step "nightly backup: a dump on the server and in the bucket"
sh backup.sh
name=$(basename "$(ls -t "$VITRINA_BACKUP_DIR"/vitrina-*.dump | head -n 1)")
echo "$name" | grep -Eq '^vitrina-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\.dump$' || fail "unexpected name $name"
$C run --rm --no-deps -T api python -m vitrina_api.backup list | grep -qx "$name" || fail "$name is not in the bucket"

step "restore from the bucket brings back the database as it was"
flow list > /dev/null
[ "$(flow count)" = 2 ] || fail "expected 2 listings before the restore"
head -c "$(($(stat -c %s "$VITRINA_BACKUP_DIR/$name") / 2))" "$VITRINA_BACKUP_DIR/$name" > "$T/half.dump"
if (cd "$T" && sh "$T/deploy/restore.sh" half.dump --yes); then fail "a dump cut in half was restored"; fi
mkdir "$T/cut" && cp "$VITRINA_BACKUP_DIR/$name.sha256" "$T/cut/"   # 100 bytes short: pg_restore alone misses it
head -c "$(($(stat -c %s "$VITRINA_BACKUP_DIR/$name") - 100))" "$VITRINA_BACKUP_DIR/$name" > "$T/cut/$name"
if sh restore.sh "$T/cut/$name" --yes; then fail "a dump cut short at its end was restored"; fi
[ "$(flow count)" = 2 ] || fail "a refused restore changed the database"
rm "$VITRINA_BACKUP_DIR/$name"
sh restore.sh --from-bucket "$name" --yes
[ "$(flow count)" = 1 ] || fail "the restore did not bring back the backed-up database"
ls "$VITRINA_BACKUP_DIR"/before-restore-*.dump > /dev/null || fail "no copy of the database from before the restore"
[ "$(https https://vitrina.test/api/v1/health)" = '{"ok":true}' ] || fail "health after the restore"
flow check "$first_id"

step "update: a backup first, the API migrates with the worker and jobs stopped, all healthy after"
VITRINA_NO_PULL=1 VITRINA_NO_BUILD=${SMOKE_UPDATE_NO_BUILD:-} sh update.sh
docker image inspect vitrina-api:prev > /dev/null || fail "no previous image kept to go back to"
[ "$(https https://vitrina.test/api/v1/health)" = '{"ok":true}' ] || fail "health after the update"
flow check "$first_id"

step "all passed"
