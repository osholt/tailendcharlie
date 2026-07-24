"""add time-bounded observer grants

Revision ID: 0006
Revises: 0005
Create Date: 2026-07-24
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "observer_grants",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("ride_id", sa.String(length=128), nullable=False),
        sa.Column("label", sa.String(length=80), nullable=False),
        sa.Column("management_token_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("publisher_token_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("observer_token_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("snapshot_ciphertext", sa.LargeBinary(), nullable=True),
        sa.Column("snapshot_updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("snapshot_version_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_read_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_observer_grants_ride",
        "observer_grants",
        ["ride_id"],
        unique=False,
    )
    op.create_index(
        "ix_observer_grants_expiry",
        "observer_grants",
        ["expires_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_observer_grants_expiry", table_name="observer_grants")
    op.drop_index("ix_observer_grants_ride", table_name="observer_grants")
    op.drop_table("observer_grants")
