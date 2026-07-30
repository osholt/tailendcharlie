"""Add personal or whole-group scope to observer grants.

Revision ID: 0009
Revises: 0008
Create Date: 2026-07-30
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "observer_grants",
        sa.Column(
            "scope",
            sa.String(length=16),
            nullable=False,
            server_default="rider",
        ),
    )


def downgrade() -> None:
    op.drop_column("observer_grants", "scope")
