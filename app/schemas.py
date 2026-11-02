from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=72)
    full_name: str | None = Field(default=None, max_length=255)
    org_name: str = Field(min_length=2, max_length=120)
    locale: str | None = Field(default=None, max_length=10)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: EmailStr
    full_name: str | None
    locale: str
    is_active: bool
    is_superadmin: bool
    created_at: datetime


class OrgOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    slug: str
    created_at: datetime


class MembershipOut(BaseModel):
    org: OrgOut
    role: str


class MeOut(BaseModel):
    user: UserOut
    memberships: list[MembershipOut]


class OrgCreateRequest(BaseModel):
    name: str = Field(min_length=2, max_length=120)


class OrgUserCreate(BaseModel):
    email: EmailStr
    full_name: str | None = Field(default=None, max_length=255)
    password: str | None = Field(default=None, min_length=8, max_length=72)
    role: str = "editor"


class OrgUserUpdate(BaseModel):
    role: str


class OrgUserOut(BaseModel):
    user_id: uuid.UUID
    email: EmailStr
    full_name: str | None
    role: str
    is_active: bool


class ChannelOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    platform: str
    platform_channel_id: str
    title: str
    handle: str | None
    thumbnail_url: str | None
    subscriber_count: int | None
    video_count: int | None
    view_count: int | None
    token_expires_at: datetime | None
    created_at: datetime


class YouTubeConnectOut(BaseModel):
    authorization_url: str


class LocaleOut(BaseModel):
    code: str
    name: str
    native_name: str
    direction: str


class LocaleResolveOut(BaseModel):
    locale: str
    direction: str


class LocaleCatalogOut(BaseModel):
    locale: str
    direction: str
    messages: dict[str, str]


class LocaleUpdate(BaseModel):
    locale: str = Field(min_length=2, max_length=10)
