"""Add location-free, opt-in ETA calibration profiles.

Revision ID: 0012
Revises: 0011
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0012"
down_revision: str | None = "0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "eta_profiles",
        sa.Column("credential_hash", sa.LargeBinary(32), nullable=False),
        sa.Column("bands", sa.JSON(), nullable=False),
        sa.Column("expires_on", sa.Date(), nullable=False),
        sa.PrimaryKeyConstraint("credential_hash"),
    )
    op.create_index("ix_eta_profiles_expires_on", "eta_profiles", ["expires_on"])


def downgrade() -> None:
    op.drop_table("eta_profiles")
