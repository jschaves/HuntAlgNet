from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from googleapiclient.discovery import build
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.crypto import decrypt_str, encrypt_str
from app.db.models import Channel

TOKEN_URI = "https://oauth2.googleapis.com/token"
AUTHORIZATION_URI = "https://accounts.google.com/o/oauth2/auth"


class YouTubeError(RuntimeError):
    pass


def _client_config() -> dict[str, Any]:
    if not settings.google_client_id or not settings.google_client_secret:
        raise YouTubeError("Google OAuth credentials are not configured")
    return {
        "web": {
            "client_id": settings.google_client_id,
            "client_secret": settings.google_client_secret,
            "auth_uri": AUTHORIZATION_URI,
            "token_uri": TOKEN_URI,
            "redirect_uris": [settings.google_redirect_uri],
        }
    }


def _build_flow() -> Flow:
    return Flow.from_client_config(
        _client_config(),
        scopes=settings.youtube_scope_list,
        redirect_uri=settings.google_redirect_uri,
    )


def build_authorization_url(state: str) -> str:
    flow = _build_flow()
    url, _ = flow.authorization_url(
        access_type="offline",
        include_granted_scopes="true",
        prompt="consent",
        state=state,
    )
    return url


def exchange_code(code: str) -> Credentials:
    flow = _build_flow()
    flow.fetch_token(code=code)
    return flow.credentials


def _as_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def fetch_my_channel(credentials: Credentials) -> dict[str, Any]:
    service = build("youtube", "v3", credentials=credentials, cache_discovery=False)
    response = service.channels().list(part="snippet,statistics", mine=True).execute()
    items = response.get("items", [])
    if not items:
        raise YouTubeError("No YouTube channel found for this Google account")

    item = items[0]
    snippet = item.get("snippet", {})
    statistics = item.get("statistics", {})
    thumbnails = snippet.get("thumbnails", {})

    return {
        "id": item["id"],
        "title": snippet.get("title", "YouTube channel"),
        "handle": snippet.get("customUrl"),
        "thumbnail_url": thumbnails.get("default", {}).get("url"),
        "subscriber_count": _to_int(statistics.get("subscriberCount")),
        "video_count": _to_int(statistics.get("videoCount")),
        "view_count": _to_int(statistics.get("viewCount")),
    }


def _to_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def apply_credentials(channel: Channel, credentials: Credentials) -> None:
    if credentials.token:
        channel.access_token = encrypt_str(credentials.token)
    if credentials.refresh_token:
        channel.refresh_token = encrypt_str(credentials.refresh_token)
    channel.token_expires_at = _as_utc(credentials.expiry)
    if credentials.scopes:
        channel.scopes = " ".join(credentials.scopes)


def refresh_channel_credentials(db: Session, channel: Channel) -> Credentials:
    if not channel.refresh_token:
        raise YouTubeError("Channel has no refresh token")

    credentials = Credentials(
        token=decrypt_str(channel.access_token) if channel.access_token else None,
        refresh_token=decrypt_str(channel.refresh_token),
        token_uri=TOKEN_URI,
        client_id=settings.google_client_id,
        client_secret=settings.google_client_secret,
        scopes=(channel.scopes or "").split() or settings.youtube_scope_list,
    )

    if not credentials.valid:
        credentials.refresh(Request())
        apply_credentials(channel, credentials)
        db.commit()
        db.refresh(channel)

    return credentials
