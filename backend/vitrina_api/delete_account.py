"""Deletes an account for someone who cannot open the app, as the public /delete-account page promises: the same
steps as Profile -> Delete account in the app. First make sure the request comes from the number's owner, for
example by calling that number back.

    python -m vitrina_api.delete_account +77010000000          # shows the account, changes nothing
    python -m vitrina_api.delete_account +77010000000 --yes    # deletes it

On the server: docker compose -f /opt/vitrina/deploy/compose.yml exec api python -m vitrina_api.delete_account ...
"""
from __future__ import annotations

import argparse
import re
import sys


def phone_of(raw: str) -> str:
    """+7 701 000 00 00, 87010000000 and 7010000000 all name +77010000000."""
    digits = re.sub(r"\D", "", raw)
    if len(digits) == 11 and digits[0] in "78":
        digits = digits[1:]
    return f"+7{digits}"


def main(argv: list[str] | None = None) -> int:
    from sqlalchemy import select

    from .auth_routes import delete_account
    from .config import Settings
    from .errors import MESSAGES, ApiError
    from .models import User, make_session_factory

    parser = argparse.ArgumentParser(description="Delete the account registered to a phone number.")
    parser.add_argument("phone", help="the account's number, e.g. +77010000000")
    parser.add_argument("--yes", action="store_true", help="delete it; without it only show the account")
    args = parser.parse_args(argv)
    phone = phone_of(args.phone)
    sessions = make_session_factory(Settings().database_url, create_schema=False)
    with sessions() as db:
        user = db.scalar(select(User).where(User.phone == phone))
        if user is None:
            print(f"no account with the number {phone}", file=sys.stderr)
            return 1
        print(f"account {user.id}: {user.display_name or '-'}, shop {user.shop_name or '-'}, "
              f"since {user.created_at:%Y-%m-%d}")
        if not args.yes:
            print("nothing changed; add --yes to delete it")
            return 0
        try:
            delete_account(db, user)
        except ApiError as e:
            print(f"not deleted ({e.code}): {MESSAGES[e.code][2]}", file=sys.stderr)
            return 2
    print(f"deleted account {user.id}; the number {phone} is free again")
    return 0


if __name__ == "__main__":
    sys.exit(main())
