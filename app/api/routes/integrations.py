from __future__ import annotations

import uuid
from urllib.parse import quote

from fastapi import APIRouter, Depends, Query
from fastapi.responses import RedirectResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.deps import TenantContext, get_db, get_tenant_context
from app.core.permissions import ensure_role
from app.core.security import create_oauth_state, decode_oauth_state
from app.db.models import Channel, Org, Platform, Role, User
from app.schemas import YouTubeConnectOut
from app.services.audit import record_audit
from app.services.youtube import (
    apply_credentials,
    build_authorization_url,
    exchange_code,
    fetch_my_channel,
)

router = APIRouter(prefix="/integrations", tags=["integrations"])


def _redirect(status: str, reason: str | None = None) -> RedirectResponse:
    url = f"{settings.frontend_url.rstrip('/')}/integrations?status={quote(status)}"
    if reason:
        url = f"{url}&reason={quote(reason)}"
    return RedirectResponse(url=url, status_code=303)


@router.get("/youtube/connect", response_model=YouTubeConnectOut)
def youtube_connect(
    context: TenantContext = Depends(get_tenant_context),
) -> YouTubeConnectOut:
    ensure_role(context, Role.ADMIN)
    state = create_oauth_state(context.org.id, context.user.id)
    return YouTubeConnectOut(authorization_url=build_authorization_url(state))


@router.get("/youtube/callback")
def youtube_callback(
    code: str | None = Query(default=None),
    state: str | None = Query(default=None),
    error: str | None = Query(default=None),
    db: Session = Depends(get_db),
) -> RedirectResponse:
    if error:
        return _redirect("error", error)
    if not code or not state:
        return _redirect("error", "missing_code_or_state")

    try:
        payload = decode_oauth_state(state)
        org_id = uuid.UUID(str(payload["org_id"]))
        user_id = uuid.UUID(str(payload["sub"]))
    except Exception:
        return _redirect("error", "invalid_state")

    org = db.get(Org, org_id)
    user = db.get(User, user_id)
    if org is None or user is None:
        return _redirect("error", "unknown_org_or_user")

    try:
        credentials = exchange_code(code)
        info = fetch_my_channel(credentials)
    except Exception:
        return _redirect("error", "youtube_exchange_failed")

    existing = db.scalar(
        select(Channel).where(
            Channel.platform == Platform.YOUTUBE,
            Channel.platform_channel_id == info["id"],
        )
    )
    if existing is not None and existing.org_id != org.id:
        return _redirect("error", "channel_already_connected")

    if existing is None:
        channel = Channel(
            org_id=org.id,
            platform=Platform.YOUTUBE,
            platform_channel_id=info["id"],
            title=info["title"],
            handle=info["handle"],
            thumbnail_url=info["thumbnail_url"],
            subscriber_count=info["subscriber_count"],
            video_count=info["video_count"],
            view_count=info["view_count"],
            connected_by_user_id=user.id,
        )
        apply_credentials(channel, credentials)
        db.add(channel)
        action = "channel.connected"
    else:
        channel = existing
        channel.title = info["title"]
        channel.handle = info["handle"]
        channel.thumbnail_url = info["thumbnail_url"]
        channel.subscriber_count = info["subscriber_count"]
        channel.video_count = info["video_count"]
        channel.view_count = info["view_count"]
        channel.connected_by_user_id = user.id
        apply_credentials(channel, credentials)
        action = "channel.reconnected"

    record_audit(
        db,
        action,
        org_id=org.id,
        user_id=user.id,
        meta={"channel_id": info["id"], "platform": Platform.YOUTUBE},
    )
    db.commit()
    return _redirect("connected")
