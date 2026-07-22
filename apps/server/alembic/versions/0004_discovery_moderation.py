"""Add moderated motorcycle discovery submissions.

Revision ID: 0004
Revises: 0003
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | None = None


def upgrade() -> None:
    op.create_table(
        "discovery_suggestions",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("client_submission_id", sa.String(length=128), nullable=False),
        sa.Column("request_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("category", sa.String(length=32), nullable=False),
        sa.Column("action", sa.String(length=16), nullable=False),
        sa.Column("target_feature_id", sa.String(length=128), nullable=True),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("evidence_url", sa.String(length=500), nullable=True),
        sa.Column("geometry_json", sa.JSON(), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("submitted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("reviewer", sa.String(length=120), nullable=True),
        sa.Column("moderation_reason", sa.Text(), nullable=True),
        sa.Column("published_feature_id", sa.String(length=128), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "client_submission_id",
            name="uq_discovery_suggestion_client_submission",
        ),
    )
    op.create_index(
        "ix_discovery_suggestions_status",
        "discovery_suggestions",
        ["status", "submitted_at"],
    )
    op.create_table(
        "discovery_moderation_events",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("suggestion_id", sa.String(length=36), nullable=False),
        sa.Column("action", sa.String(length=24), nullable=False),
        sa.Column("actor", sa.String(length=120), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["suggestion_id"],
            ["discovery_suggestions.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_discovery_moderation_suggestion",
        "discovery_moderation_events",
        ["suggestion_id", "created_at"],
    )
    op.create_table(
        "discovery_features",
        sa.Column("id", sa.String(length=128), nullable=False),
        sa.Column("category", sa.String(length=32), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("geometry_json", sa.JSON(), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("confidence", sa.String(length=16), nullable=False),
        sa.Column("source_name", sa.String(length=120), nullable=False),
        sa.Column("source_feature_id", sa.String(length=128), nullable=False),
        sa.Column("source_url", sa.String(length=500), nullable=True),
        sa.Column("warning", sa.Text(), nullable=False),
        sa.Column("approved_revision_id", sa.String(length=36), nullable=False),
        sa.Column("last_verified_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["approved_revision_id"],
            ["discovery_suggestions.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_discovery_features_public",
        "discovery_features",
        ["status", "category"],
    )


def downgrade() -> None:
    op.drop_index("ix_discovery_features_public", table_name="discovery_features")
    op.drop_table("discovery_features")
    op.drop_index(
        "ix_discovery_moderation_suggestion",
        table_name="discovery_moderation_events",
    )
    op.drop_table("discovery_moderation_events")
    op.drop_index(
        "ix_discovery_suggestions_status",
        table_name="discovery_suggestions",
    )
    op.drop_table("discovery_suggestions")
