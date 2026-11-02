from __future__ import annotations

import re
import unicodedata

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import Org


def slugify(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value)
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_value.lower()).strip("-")
    return slug or "org"


def unique_org_slug(db: Session, name: str) -> str:
    base = slugify(name)
    slug = base
    counter = 2
    while db.scalar(select(Org.id).where(Org.slug == slug)) is not None:
        slug = f"{base}-{counter}"
        counter += 1
    return slug
