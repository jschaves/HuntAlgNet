from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

import jwt
from passlib.context import CryptContext

from app.core.config import settings

ALGORITHM = "HS256"

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    try:
        return pwd_context.verify(plain_password, hashed_password)
    except (ValueError, TypeError):
        return False


def _encode(
    subject: str,
    token_type: str,
    expires_minutes: int,
    extra: dict[str, Any] | None = None,
) -> str:
    now = datetime.now(timezone.utc)
    payload: dict[str, Any] = {
        "sub": subject,
        "type": token_type,
        "iat": now,
        "exp": now + timedelta(minutes=expires_minutes),
    }
    if extra:
        payload.update(extra)
    return jwt.encode(payload, settings.secret_key, algorithm=ALGORITHM)


def create_access_token(user_id: Any) -> str:
    return _encode(str(user_id), "access", settings.access_token_expire_minutes)


def create_oauth_state(org_id: Any, user_id: Any) -> str:
    return _encode(
        str(user_id),
        "oauth_state",
        settings.oauth_state_expire_minutes,
        {"org_id": str(org_id)},
    )


def decode_token(token: str) -> dict[str, Any]:
    return jwt.decode(token, settings.secret_key, algorithms=[ALGORITHM])


def decode_oauth_state(token: str) -> dict[str, Any]:
    payload = decode_token(token)
    if payload.get("type") != "oauth_state":
        raise jwt.InvalidTokenError("invalid token type")
    if not payload.get("org_id"):
        raise jwt.InvalidTokenError("missing org_id")
    return payload
