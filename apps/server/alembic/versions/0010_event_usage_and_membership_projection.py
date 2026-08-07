"""Add constant-time event usage and push membership projections.

Revision ID: 0010
Revises: 0009
Create Date: 2026-08-04
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "rides",
        sa.Column("stored_event_count", sa.Integer(), nullable=False, server_default="0"),
    )
    op.add_column(
        "rides",
        sa.Column("stored_event_bytes", sa.BigInteger(), nullable=False, server_default="0"),
    )
    # Existing encrypted journals are rebuilt once by the application. New
    # rides are explicitly marked ready when claimed.
    op.add_column(
        "rides",
        sa.Column(
            "membership_projection_ready",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )
    op.create_table(
        "ride_members",
        sa.Column("ride_id", sa.String(length=128), nullable=False),
        sa.Column("device_id", sa.String(length=128), nullable=False),
        sa.Column("role", sa.String(length=32), nullable=False),
        sa.Column("state", sa.String(length=16), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("ride_id", "device_id"),
    )
    op.execute(
        sa.text(
            """
            UPDATE rides
            SET stored_event_count = (
                    SELECT COUNT(*) FROM ride_events WHERE ride_events.ride_id = rides.id
                ),
                stored_event_bytes = (
                    SELECT COALESCE(SUM(LENGTH(body_ciphertext)), 0)
                    FROM ride_events
                    WHERE ride_events.ride_id = rides.id
                )
            """
        )
    )


def downgrade() -> None:
    op.drop_table("ride_members")
    op.drop_column("rides", "membership_projection_ready")
    op.drop_column("rides", "stored_event_bytes")
    op.drop_column("rides", "stored_event_count")
