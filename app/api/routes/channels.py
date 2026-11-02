from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.deps import TenantContext, get_db, get_tenant_context
from app.core.permissions import ensure_role
from app.db.models import Channel, Role
from app.schemas import ChannelOut
from app.services.audit import record_audit
from app.services.youtube import YouTubeError, refresh_channel_credentials

router = APIRouter(prefix="/channels", tags=["channels"])


@router.get("", response_model=list[ChannelOut])
def list_channels(
    context: TenantContext = Depends(get_tenant_context),
    db: Session = Depends(get_db),
) -> list[Channel]:
    ensure_role(context, Role.VIEWER)
    return list(
        db.scalars(
            select(Channel)
            .where(Channel.org_id == context.org.id)
            .order_by(Channel.created_at)
        ).all()
    )


@router.delete("/{channel_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_channel(
    channel_id: uuid.UUID,
    context: TenantContext = Depends(get_tenant_context),
    db: Session = Depends(get_db),
) -> None:
    ensure_role(context, Role.ADMIN)
    channel = db.get(Channel, channel_id)
    if channel is None or channel.org_id != context.org.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Channel not found")

    record_audit(
        db,
        "channel.disconnected",
        org_id=context.org.id,
        user_id=context.user.id,
        meta={"channel_id": str(channel.id), "platform": channel.platform},
    )
    db.delete(channel)
    db.commit()


@router.post("/{channel_id}/refresh", response_model=ChannelOut)
def refresh_channel(
    channel_id: uuid.UUID,
    context: TenantContext = Depends(get_tenant_context),
    db: Session = Depends(get_db),
) -> Channel:
    ensure_role(context, Role.ADMIN)
    channel = db.get(Channel, channel_id)
    if channel is None or channel.org_id != context.org.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Channel not found")

    try:
        refresh_channel_credentials(db, channel)
    except YouTubeError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Could not refresh YouTube credentials",
        ) from exc

    db.refresh(channel)
    return channel
