from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.core.deps import get_current_user, get_db
from app.core.permissions import assert_org_access
from app.core.security import hash_password
from app.core.utils import unique_org_slug
from app.db.models import Membership, Org, Role, User
from app.schemas import (
    OrgCreateRequest,
    OrgOut,
    OrgUserCreate,
    OrgUserOut,
    OrgUserUpdate,
)
from app.services.audit import record_audit

router = APIRouter(prefix="/orgs", tags=["orgs"])


def _member_out(membership: Membership) -> OrgUserOut:
    return OrgUserOut(
        user_id=membership.user_id,
        email=membership.user.email,
        full_name=membership.user.full_name,
        role=membership.role,
        is_active=membership.user.is_active,
    )


@router.get("", response_model=list[OrgOut])
def list_orgs(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Org]:
    if user.is_superadmin:
        return list(db.scalars(select(Org).order_by(Org.name)).all())

    return list(
        db.scalars(
            select(Org)
            .join(Membership, Membership.org_id == Org.id)
            .where(Membership.user_id == user.id)
            .order_by(Org.name)
        ).all()
    )


@router.post("", response_model=OrgOut, status_code=status.HTTP_201_CREATED)
def create_org(
    payload: OrgCreateRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Org:
    org = Org(name=payload.name, slug=unique_org_slug(db, payload.name))
    db.add(org)
    db.flush()
    db.add(Membership(user_id=user.id, org_id=org.id, role=Role.OWNER))
    record_audit(db, "org.created", org_id=org.id, user_id=user.id, meta={"name": org.name})
    db.commit()
    db.refresh(org)
    return org


@router.get("/{org_id}/users", response_model=list[OrgUserOut])
def list_org_users(
    org_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[OrgUserOut]:
    org, _ = assert_org_access(db, user, org_id, Role.ADMIN)
    rows = db.scalars(
        select(Membership)
        .options(selectinload(Membership.user))
        .where(Membership.org_id == org.id)
        .order_by(Membership.created_at)
    ).all()
    return [_member_out(row) for row in rows]


@router.post(
    "/{org_id}/users",
    response_model=OrgUserOut,
    status_code=status.HTTP_201_CREATED,
)
def create_org_user(
    org_id: uuid.UUID,
    payload: OrgUserCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> OrgUserOut:
    org, actor_membership = assert_org_access(db, user, org_id, Role.ADMIN)

    if payload.role not in Role.ASSIGNABLE:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Role must be one of: {', '.join(sorted(Role.ASSIGNABLE))}",
        )
    actor_is_owner = user.is_superadmin or (
        actor_membership is not None and actor_membership.role == Role.OWNER
    )
    if payload.role == Role.ADMIN and not actor_is_owner:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only owners can assign the admin role",
        )

    email = str(payload.email).lower()
    target = db.scalar(select(User).where(func.lower(User.email) == email))
    if target is None:
        if not payload.password:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Password is required for new users",
            )
        target = User(
            email=email,
            hashed_password=hash_password(payload.password),
            full_name=payload.full_name,
        )
        db.add(target)
        db.flush()
    else:
        exists = db.scalar(
            select(Membership.id).where(
                Membership.user_id == target.id,
                Membership.org_id == org.id,
            )
        )
        if exists is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="User already belongs to this organization",
            )

    membership = Membership(user_id=target.id, org_id=org.id, role=payload.role)
    db.add(membership)
    record_audit(
        db,
        "org.user_added",
        org_id=org.id,
        user_id=user.id,
        meta={"target_user_id": str(target.id), "role": payload.role},
    )
    db.commit()
    db.refresh(membership)
    membership.user = target
    return _member_out(membership)


@router.patch("/{org_id}/users/{user_id}", response_model=OrgUserOut)
def update_org_user(
    org_id: uuid.UUID,
    user_id: uuid.UUID,
    payload: OrgUserUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> OrgUserOut:
    org, actor_membership = assert_org_access(db, user, org_id, Role.ADMIN)

    if payload.role not in Role.ALL:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Role must be one of: {', '.join(sorted(Role.ALL))}",
        )

    target = db.scalar(
        select(Membership)
        .options(selectinload(Membership.user))
        .where(Membership.org_id == org.id, Membership.user_id == user_id)
    )
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Membership not found")

    actor_is_owner = user.is_superadmin or (
        actor_membership is not None and actor_membership.role == Role.OWNER
    )
    if not actor_is_owner and (target.role == Role.OWNER or payload.role == Role.OWNER):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only owners can manage the owner role",
        )

    if target.role == Role.OWNER and payload.role != Role.OWNER:
        owners = db.scalar(
            select(func.count())
            .select_from(Membership)
            .where(Membership.org_id == org.id, Membership.role == Role.OWNER)
        )
        if (owners or 0) <= 1:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Cannot demote the last owner",
            )

    target.role = payload.role
    record_audit(
        db,
        "org.user_role_changed",
        org_id=org.id,
        user_id=user.id,
        meta={"target_user_id": str(user_id), "role": payload.role},
    )
    db.commit()
    return _member_out(target)


@router.delete("/{org_id}/users/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_org_user(
    org_id: uuid.UUID,
    user_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    org, actor_membership = assert_org_access(db, user, org_id, Role.ADMIN)

    target = db.scalar(
        select(Membership).where(
            Membership.org_id == org.id,
            Membership.user_id == user_id,
        )
    )
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Membership not found")

    actor_is_owner = user.is_superadmin or (
        actor_membership is not None and actor_membership.role == Role.OWNER
    )
    if not actor_is_owner and target.role in {Role.OWNER, Role.ADMIN}:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only owners can remove owners or admins",
        )

    if target.role == Role.OWNER:
        owners = db.scalar(
            select(func.count())
            .select_from(Membership)
            .where(Membership.org_id == org.id, Membership.role == Role.OWNER)
        )
        if (owners or 0) <= 1:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Cannot remove the last owner",
            )

    db.delete(target)
    record_audit(
        db,
        "org.user_removed",
        org_id=org.id,
        user_id=user.id,
        meta={"target_user_id": str(user_id)},
    )
    db.commit()
