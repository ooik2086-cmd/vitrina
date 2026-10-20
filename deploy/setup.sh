#!/bin/sh
# Prepares a fresh Ubuntu 22.04 or 24.04 server and starts VITRINA on it. Run as root from the repository:
#
#   git clone https://github.com/ooik2086-cmd/vitrina /opt/vitrina
#   sh /opt/vitrina/deploy/setup.sh vitrina.kz you@example.kz
#
# It installs Docker, turns on the firewall (only ssh, 80 and 443), adds 2 GB of swap, turns on security updates,
# writes deploy/.env with new random secrets (once: an existing .env is never overwritten), checks the domain,
# starts everything, checks the three buckets, makes the first backup and installs the nightly one. Run it again after filling the S3 lines in deploy/.env; it is safe to repeat.
#
#   sh deploy/setup.sh --env-only DOMAIN EMAIL   only writes deploy/.env (nothing installed or started)
set -eu

DEPLOY=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$DEPLOY/.env"
ENV_ONLY=0
if [ "${1:-}" = "--env-only" ]; then ENV_ONLY=1; shift; fi
DOMAIN=${1:-}
EMAIL=${2:-}

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

write_env() {
	if [ -f "$ENV_FILE" ]; then
		kept=$(sed -n 's/^VITRINA_DOMAIN=//p' "$ENV_FILE")
		if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$kept" ]; then
			die "$ENV_FILE has VITRINA_DOMAIN=$kept, not $DOMAIN. To change it, edit VITRINA_DOMAIN and VITRINA_CORS_ORIGINS (and VITRINA_TLS for the email) there, keeping the secrets, then run: sh $0"
		fi
		echo "$ENV_FILE exists: keeping it, domain $kept (its secrets are in use)"
		return
	fi
	[ -n "$DOMAIN" ] && [ -n "$EMAIL" ] || die "usage: setup.sh DOMAIN EMAIL   (e.g. setup.sh vitrina.kz you@example.kz)"
	printf '%s' "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$' || die "not a domain name: $DOMAIN"
	printf '%s' "$EMAIL" | grep -Eq '^[^@ ]+@[^@ ]+\.[^@ ]+$' || die "not an email: $EMAIL"
	command -v openssl >/dev/null || die "openssl is missing"
	umask 077
	sed -e "s|^VITRINA_DOMAIN=.*|VITRINA_DOMAIN=$DOMAIN|" \
		-e "s|^VITRINA_TLS=.*|VITRINA_TLS=$EMAIL|" \
		-e "s|^VITRINA_CORS_ORIGINS=.*|VITRINA_CORS_ORIGINS=https://$DOMAIN|" \
		-e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 32)|" \
		-e "s|^VITRINA_OTP_SECRET=.*|VITRINA_OTP_SECRET=$(openssl rand -hex 32)|" \
		-e "s|^VITRINA_PAYMENT_SECRET=.*|VITRINA_PAYMENT_SECRET=$(openssl rand -hex 32)|" \
		-e "s|^VITRINA_DELIVERY_SECRET=.*|VITRINA_DELIVERY_SECRET=$(openssl rand -hex 32)|" \
		"$DEPLOY/.env.example" > "$ENV_FILE.tmp"
	mv "$ENV_FILE.tmp" "$ENV_FILE"
	echo "wrote $ENV_FILE (readable by root only); keep a copy of it somewhere safe"
}

# Settings only the backup scripts read, kept out of the running services.
write_backup_env() {
	[ ! -f "$DEPLOY/backup.env" ] || return 0
	umask 077
	cat > "$DEPLOY/backup.env" <<'EOF'
# Read only by backup.sh and restore.sh, never by the running services (root only, never commit it).
# A key of the backup bucket's own, if the provider can make one for that bucket alone (then take that bucket away
# from the main key in .env): a break-in through the API can then not delete the copies. Empty: the main key.
VITRINA_S3_BACKUP_ACCESS_KEY=
VITRINA_S3_BACKUP_SECRET_KEY=
# Called after every good backup, and at this address + /fail after a bad one (e.g. a free healthchecks.io check
# that emails you when the call stops coming). Empty: nobody is told when a backup fails.
VITRINA_BACKUP_PING_URL=
EOF
	echo "wrote $DEPLOY/backup.env"
}

# The domain's addresses against this server's, before Caddy asks Let's Encrypt (which fails while they differ).
check_dns() {
	domain=$(sed -n 's/^VITRINA_DOMAIN=//p' "$ENV_FILE")
	ours=$(hostname -I 2> /dev/null || true)
	four=$(getent ahostsv4 "$domain" 2> /dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ' || true)
	six=$(getent ahostsv6 "$domain" 2> /dev/null | awk '$1 !~ /^::ffff:/ { print $1 }' | sort -u | tr '\n' ' ' || true)
	if [ -z "$four" ]; then
		echo "WARNING: $domain has no A record yet. Point it at this server; the site gets its certificate after."
	else
		echo "$domain points at: $four; this server's addresses: $ours"
		for ip in $four; do
			case " $ours " in *" $ip "*) ;; *) echo "WARNING: $ip is not one of this server's addresses (fine only behind a provider's NAT)" ;; esac
		done
	fi
	[ -z "$six" ] || echo "WARNING: $domain also has an AAAA record ($six). Let's Encrypt tries it first: remove it unless it is this server."
}

# Lines of .env still empty or still the example's placeholders.
unfilled() {
	grep -E '^(VITRINA_S3_ACCESS_KEY|VITRINA_S3_SECRET_KEY)=$|^VITRINA_S3_ENDPOINT=https://s3\.example\.kz$|^VITRINA_PUBLIC_MEDIA_URL=https://s3\.example\.kz/' "$ENV_FILE" | cut -d= -f1 || true
}

if [ "$ENV_ONLY" = 1 ]; then
	write_env
	exit 0
fi

[ "$(id -u)" = 0 ] || die "run as root (sudo sh deploy/setup.sh ...)"
# shellcheck disable=SC1091  # the server's own file
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "made for Ubuntu 22.04 or 24.04, this is ${PRETTY_NAME:-unknown}"

say "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl openssl tzdata ufw unattended-upgrades
# Logs and timers in Kazakhstan time (UTC+5). The containers keep UTC.
timedatectl set-timezone Asia/Almaty || echo "could not set the time zone (logs stay in UTC)"

say "Docker"
if ! docker compose version >/dev/null 2>&1; then
	# Docker's own repository (Ubuntu's docker.io has no compose v2).
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
		> /etc/apt/sources.list.d/docker.list
	apt-get update -q
	apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

say "security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

say "swap"
# Cutting out a listing's photos takes up to 1.7 GB; swap keeps a spike from killing the database.
if [ -z "$(swapon --show --noheadings)" ]; then
	if [ ! -f /swapfile ]; then
		fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
		chmod 600 /swapfile
		mkswap /swapfile
	fi
	swapon /swapfile
	grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
swapon --show

say "firewall"
# Docker opens the published ports (80, 443) itself; nothing else is published, so ufw guards ssh and the rest.
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

say "settings"
write_env
write_backup_env
missing=$(unfilled)
if [ -n "$missing" ]; then
	echo "Fill these in $ENV_FILE (from the storage provider), then run this script again:"
	echo "$missing" | sed 's/^/  /'
	exit 2
fi

say "nightly backup"
cat > /etc/systemd/system/vitrina-backup.service <<EOF
[Unit]
Description=VITRINA database backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
Environment="VITRINA_COMPOSE_FILES=${VITRINA_COMPOSE_FILES:-}" "VITRINA_BACKUP_DIR=${VITRINA_BACKUP_DIR:-/var/backups/vitrina}"
ExecStart=/bin/sh $DEPLOY/backup.sh
EOF
cat > /etc/systemd/system/vitrina-backup.timer <<'EOF'
[Unit]
Description=VITRINA database backup every night

[Timer]
# 21:30 UTC is 02:30 in Kazakhstan, when the shop is quietest.
OnCalendar=*-*-* 21:30:00 UTC
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now vitrina-backup.timer

say "domain"
check_dns

say "start"
cd "$DEPLOY"
C="docker compose ${VITRINA_COMPOSE_FILES:-}"
$C up -d "${VITRINA_BUILD:---build}" --wait --wait-timeout 900 || {
	$C ps
	$C logs --tail 50 api
	die "a service did not become healthy; the log above says why"
}
$C ps

say "storage"
# Each bucket written, read back and deleted: wrong keys, a missing bucket or one public by mistake show now.
set -a
# shellcheck source=/dev/null
. "$DEPLOY/backup.env"
set +a
$C run --rm --no-deps -T -e VITRINA_S3_BACKUP_ACCESS_KEY -e VITRINA_S3_BACKUP_SECRET_KEY api \
	python -m vitrina_api.backup check || die "fix VITRINA_S3_* in $ENV_FILE (what is wrong is said above), then run: sh $0"

say "first backup"
sh "$DEPLOY/backup.sh" || die "the first backup failed (see above)"

DOMAIN=$(sed -n 's/^VITRINA_DOMAIN=//p' "$ENV_FILE")
say "check"
if curl -fsS --max-time 20 "https://$DOMAIN/api/v1/health"; then
	echo
	echo "VITRINA is up at https://$DOMAIN"
else
	echo "https://$DOMAIN does not answer yet. Check that the domain's A record points at this server (see the"
	echo "domain step above). Caddy asks for the certificate again with longer and longer pauses, so once DNS is"
	echo "right, make it ask now: docker compose -f $DEPLOY/compose.yml restart caddy"
	echo "What Caddy says: docker compose -f $DEPLOY/compose.yml logs caddy"
fi
