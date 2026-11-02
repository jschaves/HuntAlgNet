from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy.orm import Session

from app.db.models import AuditLog


def record_audit(
    db: Session,
    action: str,
    *,
    org_id: uuid.UUID | None = None,
    user_id: uuid.UUID | None = None,
    meta: dict[str, Any] | None = None,
) -> None:
    db.add(AuditLog(action=action, org_id=org_id, user_id=user_id, meta=meta))
