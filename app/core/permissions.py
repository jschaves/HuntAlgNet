from __future__ import annotations

import uuid

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.deps import TenantContext
from app.db.models import Membership, Org, Role, User

ROLE_RANK = {
    Role.VIEWER: 0,
    Role.ANALYST: 1,
    Role.EDITOR: 2,
    Role.ADMIN: 3,
    Role.OWNER: 4,
}


def ensure_role(context: TenantContext, minimum: str) -> None:
    if context.user.is_superadmin:
        return
    if context.membership is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient permissions")
    current = ROLE_RANK.get(context.membership.role, -1)
    required = ROLE_RANK[minimum]
    if current < required:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient permissions")


def assert_org_access(
    db: Session,
    user: User,
    org_id: uuid.UUID,
    minimum: str = Role.VIEWER,
) -> tuple[Org, Membership | None]:
    org = db.get(Org, org_id)
    if org is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Organization not found")

    if user.is_superadmin:
        return org, None

    membership = db.scalar(
        select(Membership).where(
            Membership.user_id == user.id,
            Membership.org_id == org.id,
        )
    )
    if membership is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="No access to this organization")

    if ROLE_RANK.get(membership.role, -1) < ROLE_RANK[minimum]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient permissions")

    return org, membership
