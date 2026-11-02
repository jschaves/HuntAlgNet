"""add user locale

Revision ID: 0002_user_locale
Revises: 0001_initial
Create Date: 2026-11-02

"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0002_user_locale"
down_revision: Union[str, None] = "0001_initial"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column(
            "locale",
            sa.String(length=10),
            server_default="en-US",
            nullable=False,
        ),
    )


def downgrade() -> None:
    op.drop_column("users", "locale")
