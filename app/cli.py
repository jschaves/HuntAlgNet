from __future__ import annotations

import argparse
import getpass
import sys

from sqlalchemy import func, select

from app.core.security import hash_password
from app.db.models import User
from app.db.session import SessionLocal


def create_superadmin(email: str, password: str | None, full_name: str | None) -> int:
    email = email.lower()

    if password is None:
        password = getpass.getpass("Password: ")
        confirm = getpass.getpass("Confirm password: ")
        if password != confirm:
            print("Passwords do not match", file=sys.stderr)
            return 1

    if len(password) < 8:
        print("Password must be at least 8 characters", file=sys.stderr)
        return 1
    if len(password.encode("utf-8")) > 72:
        print("Password must be at most 72 bytes", file=sys.stderr)
        return 1

    with SessionLocal() as db:
        user = db.scalar(select(User).where(func.lower(User.email) == email))
        if user is None:
            user = User(
                email=email,
                hashed_password=hash_password(password),
                full_name=full_name,
                is_superadmin=True,
                is_active=True,
            )
            db.add(user)
            print(f"Superadmin created: {email}")
        else:
            user.is_superadmin = True
            user.is_active = True
            if password:
                user.hashed_password = hash_password(password)
            if full_name:
                user.full_name = full_name
            print(f"Superadmin updated: {email}")
        db.commit()

    return 0


def check_i18n() -> int:
    from app.core.i18n import SUPPORTED_LOCALES, catalog_issues

    issues = catalog_issues()
    if issues:
        for issue in issues:
            print(issue, file=sys.stderr)
        return 1
    print(f"i18n OK: {len(SUPPORTED_LOCALES)} idiomas")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="huntalgnet")
    subparsers = parser.add_subparsers(dest="command", required=True)

    superadmin = subparsers.add_parser(
        "create-superadmin",
        help="Create or promote a superadmin user",
    )
    superadmin.add_argument("--email", required=True)
    superadmin.add_argument("--password")
    superadmin.add_argument("--name")

    subparsers.add_parser("check-i18n", help="Validate the 10 locale catalogs")

    args = parser.parse_args()

    if args.command == "create-superadmin":
        return create_superadmin(args.email, args.password, args.name)
    if args.command == "check-i18n":
        return check_i18n()

    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
