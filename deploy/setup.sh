#!/bin/sh
# Prepares a fresh Ubuntu 22.04 or 24.04 server and starts VITRINA on it. Run as root from the repository:
#
#   git clone https://github.com/ooik2086-cmd/vitrina /opt/vitrina
#   sh /opt/vitrina/deploy/setup.sh vitrina.kz you@example.kz
#
# It installs Docker, turns on the firewall (only ssh, 80 and 443), adds 2 GB of swap, turns on security updates,
# writes deploy/.env with new random secrets (once: an existing .env is never overwritten), installs the nightly
# backup and starts everything. Run it again after filling the S3 lines in deploy/.env; it is safe to repeat.
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
		echo "$ENV_FILE exists: keeping it (its secrets are in use)"
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
apt-get install -y -q ca-certificates curl openssl ufw unattended-upgrades

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

say "start"
cd "$DEPLOY"
docker compose up -d --build --wait --wait-timeout 600 || {
	docker compose ps
	docker compose logs --tail 50 api
	die "a service did not become healthy; the log above says why"
}
docker compose ps

DOMAIN=$(sed -n 's/^VITRINA_DOMAIN=//p' "$ENV_FILE")
say "check"
if curl -fsS --max-time 20 "https://$DOMAIN/api/v1/health"; then
	echo
	echo "VITRINA is up at https://$DOMAIN"
else
	echo "https://$DOMAIN does not answer yet. Check that the domain's A record points at this server; Caddy"
	echo "keeps asking for the certificate: docker compose -f $DEPLOY/compose.yml logs caddy"
fi
