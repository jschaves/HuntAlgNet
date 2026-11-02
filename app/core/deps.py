from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Generator

from fastapi import Depends, Header, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.security import decode_token
from app.db.models import Membership, Org, User
from app.db.session import SessionLocal

oauth2_scheme = OAuth2PasswordBearer(tokenUrl=f"{settings.api_prefix}/auth/login")

credentials_exception = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="Could not validate credentials",
    headers={"WWW-Authenticate": "Bearer"},
)


@dataclass
class TenantContext:
    user: User
    org: Org
    membership: Membership | None


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> User:
    try:
        payload = decode_token(token)
    except Exception as exc:
        raise credentials_exception from exc

    if payload.get("type") != "access":
        raise credentials_exception

    try:
        user_id = uuid.UUID(str(payload.get("sub")))
    except (ValueError, TypeError) as exc:
        raise credentials_exception from exc

    user = db.get(User, user_id)
    if user is None or not user.is_active:
        raise credentials_exception
    return user


def get_tenant_context(
    x_org_id: uuid.UUID = Header(..., alias="X-Org-Id"),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TenantContext:
    org = db.get(Org, x_org_id)
    if org is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Organization not found")

    if user.is_superadmin:
        return TenantContext(user=user, org=org, membership=None)

    membership = db.scalar(
        select(Membership).where(
            Membership.user_id == user.id,
            Membership.org_id == org.id,
        )
    )
    if membership is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="No access to this organization")

    return TenantContext(user=user, org=org, membership=membership)
