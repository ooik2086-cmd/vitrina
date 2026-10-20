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

# Lines of .env still empty or still the example's placeholders.
unfilled() {
	grep -E '^(VITRINA_S3_ACCESS_KEY|VITRINA_S3_SECRET_KEY|VITRINA_MOBIZON_API_KEY)=$|^VITRINA_S3_ENDPOINT=https://s3\.example\.kz$|^VITRINA_PUBLIC_MEDIA_URL=https://s3\.example\.kz/' "$ENV_FILE" | cut -d= -f1 || true
}

# Stops the calling script (exit 2) while a line needs filling, saying which and where they come from.
need_filled() {
	add_missing
	missing=$(unfilled)
	[ -n "$missing" ] || return 0
	echo "Fill these in $ENV_FILE (VITRINA_S3_*: from the storage provider, VITRINA_MOBIZON_API_KEY: from the Mobizon account), then run this script again:"
	echo "$missing" | sed 's/^/  /'
	exit 2
}
