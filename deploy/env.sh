# shellcheck shell=sh
# Sourced by setup.sh and update.sh, with DEPLOY and ENV_FILE set: deploy/.env checked against .env.example.

# Settings .env.example has and .env lacks (a newer version needs them) are added at the end of .env with the
# example's value, so an empty one is then listed by unfilled.
add_missing() {
	added=""
	keys=$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$DEPLOY/.env.example")
	for key in $keys; do
		grep -q "^$key=" "$ENV_FILE" && continue
		[ -n "$added" ] || printf '\n# Added from .env.example on %s (a newer version needs them):\n' "$(date +%F)" >> "$ENV_FILE"
		grep "^$key=" "$DEPLOY/.env.example" >> "$ENV_FILE"
		added="$added $key"
	done
	[ -z "$added" ] || echo "added to $ENV_FILE:$added"
}

# Lines of .env still empty that the chosen storage needs (and VITRINA_STORAGE itself, until it is disk or s3).
unfilled() {
	case $(sed -n 's/^VITRINA_STORAGE=//p' "$ENV_FILE" | tail -n 1) in
		disk) need='VITRINA_PUBLIC_API_URL|VITRINA_PUBLIC_MEDIA_URL' ;;
		s3) need='VITRINA_PUBLIC_MEDIA_URL|VITRINA_S3_ENDPOINT|VITRINA_S3_ACCESS_KEY|VITRINA_S3_SECRET_KEY|VITRINA_S3_BUCKET|VITRINA_S3_PRIVATE_BUCKET|VITRINA_S3_BACKUP_BUCKET' ;;
		*) echo "VITRINA_STORAGE (disk or s3)"; need=VITRINA_STORAGE ;;
	esac
	grep -E "^(VITRINA_MOBIZON_API_KEY|$need)=\$" "$ENV_FILE" | cut -d= -f1 | grep -vx VITRINA_STORAGE || true
}

# Stops the calling script (exit 2) while a line needs filling, saying which and where they come from.
need_filled() {
	add_missing
	missing=$(unfilled)
	[ -n "$missing" ] || return 0
	echo "Fill these in $ENV_FILE (VITRINA_S3_*: from the storage provider, VITRINA_MOBIZON_API_KEY: from the Mobizon account; deploy/README.md), then run this script again:"
	echo "$missing" | sed 's/^/  /'
	exit 2
}
