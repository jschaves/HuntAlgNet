from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.core.deps import get_current_user, get_db
from app.core.i18n import negotiate_locale, normalize_locale, translate
from app.core.security import create_access_token, hash_password, verify_password
from app.core.utils import unique_org_slug
from app.db.models import Membership, Org, Role, User
from app.schemas import (
    LocaleUpdate,
    LoginRequest,
    MeOut,
    MembershipOut,
    OrgOut,
    RegisterRequest,
    TokenResponse,
    UserOut,
)
from app.services.audit import record_audit

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
def register(
    payload: RegisterRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> TokenResponse:
    locale = normalize_locale(payload.locale) or negotiate_locale(
        request.headers.get("accept-language")
    )
    email = str(payload.email).lower()
    if db.scalar(select(User.id).where(func.lower(User.email) == email)) is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=translate("errors.email_taken", locale),
        )

    user = User(
        email=email,
        hashed_password=hash_password(payload.password),
        full_name=payload.full_name,
        locale=locale,
    )
    org = Org(name=payload.org_name, slug=unique_org_slug(db, payload.org_name))
    db.add_all([user, org])
    db.flush()

    db.add(Membership(user_id=user.id, org_id=org.id, role=Role.OWNER))
    record_audit(db, "org.created", org_id=org.id, user_id=user.id, meta={"name": org.name})
    db.commit()

    return TokenResponse(access_token=create_access_token(user.id))


@router.post("/login", response_model=TokenResponse)
def login(
    payload: LoginRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> TokenResponse:
    locale = negotiate_locale(request.headers.get("accept-language"))
    email = str(payload.email).lower()
    user = db.scalar(select(User).where(func.lower(User.email) == email))
    if user is None or not verify_password(payload.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=translate("errors.invalid_credentials", locale),
        )
    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=translate("errors.unauthorized", user.locale),
        )

    return TokenResponse(access_token=create_access_token(user.id))


@router.get("/me", response_model=MeOut)
def me(user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> MeOut:
    if user.is_superadmin:
        orgs = db.scalars(select(Org).order_by(Org.name)).all()
        memberships = [
            MembershipOut(org=OrgOut.model_validate(org), role="superadmin") for org in orgs
        ]
    else:
        rows = db.scalars(
            select(Membership)
            .options(selectinload(Membership.org))
            .where(Membership.user_id == user.id)
            .order_by(Membership.created_at)
        ).all()
        memberships = [
            MembershipOut(org=OrgOut.model_validate(row.org), role=row.role) for row in rows
        ]

    return MeOut(user=UserOut.model_validate(user), memberships=memberships)


@router.patch("/me/locale", response_model=UserOut)
def update_my_locale(
    payload: LocaleUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    locale = normalize_locale(payload.locale)
    if locale is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=translate("errors.language_not_supported", user.locale),
        )

    user.locale = locale
    db.commit()
    db.refresh(user)
    return user
