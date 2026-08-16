"""Add privacy-separated aggregate ride heatmap storage.

Revision ID: 0011
Revises: 0010
Create Date: 2026-08-16
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "heatmap_contributors",
        sa.Column("handle_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("proof_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("consent_version", sa.String(length=40), nullable=False),
        sa.Column("created_on", sa.Date(), nullable=False),
        sa.Column("last_seen_on", sa.Date(), nullable=False),
        sa.PrimaryKeyConstraint("handle_hash"),
    )
    op.create_table(
        "heatmap_contributor_cells",
        sa.Column("handle_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("receipt_month", sa.Date(), nullable=False),
        sa.Column("z", sa.Integer(), nullable=False),
        sa.Column("x", sa.Integer(), nullable=False),
        sa.Column("y", sa.Integer(), nullable=False),
        sa.Column("visit_count", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(
            ["handle_hash"],
            ["heatmap_contributors.handle_hash"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("handle_hash", "receipt_month", "z", "x", "y"),
    )
    op.create_index(
        "ix_heatmap_contributor_cells_cell",
        "heatmap_contributor_cells",
        ["z", "x", "y"],
    )
    op.create_index(
        "ix_heatmap_contributor_cells_month",
        "heatmap_contributor_cells",
        ["receipt_month"],
    )
    op.create_table(
        "heatmap_upload_receipts",
        sa.Column("handle_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("upload_id_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("received_on", sa.Date(), nullable=False),
        sa.Column("delete_after", sa.Date(), nullable=False),
        sa.ForeignKeyConstraint(
            ["handle_hash"],
            ["heatmap_contributors.handle_hash"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("handle_hash", "upload_id_hash"),
    )
    op.create_index(
        "ix_heatmap_upload_receipts_expiry",
        "heatmap_upload_receipts",
        ["delete_after"],
    )
    op.create_table(
        "heatmap_snapshots",
        sa.Column("version", sa.String(length=40), nullable=False),
        sa.Column("published_on", sa.Date(), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.PrimaryKeyConstraint("version"),
    )
    op.create_index(
        "ix_heatmap_snapshots_active",
        "heatmap_snapshots",
        ["active", "published_on"],
    )
    op.create_table(
        "heatmap_public_cells",
        sa.Column("snapshot_version", sa.String(length=40), nullable=False),
        sa.Column("z", sa.Integer(), nullable=False),
        sa.Column("x", sa.Integer(), nullable=False),
        sa.Column("y", sa.Integer(), nullable=False),
        sa.Column("contributor_bucket", sa.String(length=8), nullable=False),
        sa.Column("intensity_bucket", sa.String(length=16), nullable=False),
        sa.ForeignKeyConstraint(
            ["snapshot_version"],
            ["heatmap_snapshots.version"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("snapshot_version", "z", "x", "y"),
    )
    op.create_index(
        "ix_heatmap_public_cells_view",
        "heatmap_public_cells",
        ["snapshot_version", "z", "x", "y"],
    )


def downgrade() -> None:
    op.drop_table("heatmap_public_cells")
    op.drop_table("heatmap_snapshots")
    op.drop_table("heatmap_upload_receipts")
    op.drop_table("heatmap_contributor_cells")
    op.drop_table("heatmap_contributors")
