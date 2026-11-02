from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import or_, select

from app.db.models import Channel, Platform
from app.db.session import SessionLocal
from app.services.youtube import refresh_channel_credentials
from worker.celery_app import celery_app

logger = logging.getLogger(__name__)


@celery_app.task(name="worker.tasks.refresh_expiring_youtube_tokens")
def refresh_expiring_youtube_tokens() -> int:
    now = datetime.now(timezone.utc)
    threshold = now + timedelta(minutes=60)
    refreshed = 0

    with SessionLocal() as db:
        channels = db.scalars(
            select(Channel).where(
                Channel.platform == Platform.YOUTUBE,
                Channel.refresh_token.is_not(None),
                or_(
                    Channel.token_expires_at.is_(None),
                    Channel.token_expires_at <= threshold,
                ),
            )
        ).all()

        for channel in channels:
            try:
                refresh_channel_credentials(db, channel)
                refreshed += 1
            except Exception:
                logger.exception("Failed to refresh YouTube token for channel %s", channel.id)

    return refreshed
