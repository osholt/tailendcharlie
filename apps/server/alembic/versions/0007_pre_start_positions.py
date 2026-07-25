"""add replace-only encrypted pre-start positions

Revision ID: 0007
Revises: 0006
Create Date: 2026-07-25
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "pre_start_positions",
        sa.Column("ride_id", sa.String(length=128), nullable=False),
        sa.Column("rider_id", sa.String(length=128), nullable=False),
        sa.Column("snapshot_ciphertext", sa.LargeBinary(), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("ride_id", "rider_id"),
    )
    op.create_index(
        "ix_pre_start_positions_expiry",
        "pre_start_positions",
        ["expires_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_pre_start_positions_expiry", table_name="pre_start_positions")
    op.drop_table("pre_start_positions")
