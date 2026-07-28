"""Add anonymous rider road-rating tallies.

A tally table, not a submission log. There is deliberately no row that
represents one rating: the primary key is
(feature_id, catalogue_version, verdict) and a submission increments a counter,
so the relay cannot reconstruct who rated what even from a full database dump.
Dates rather than timestamps for the same reason - a receipt second is a
correlation handle against the ride journal, a receipt day is not (issue #159).

Revision ID: 0008
Revises: 0007
Create Date: 2026-07-28
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "discovery_road_ratings",
        sa.Column("feature_id", sa.String(length=128), nullable=False),
        sa.Column("catalogue_version", sa.String(length=64), nullable=False),
        sa.Column("verdict", sa.String(length=24), nullable=False),
        sa.Column("category", sa.String(length=32), nullable=False),
        sa.Column("source_feature_id", sa.String(length=128), nullable=True),
        sa.Column("rating_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("first_rated_on", sa.Date(), nullable=False),
        sa.Column("last_rated_on", sa.Date(), nullable=False),
        sa.PrimaryKeyConstraint(
            "feature_id",
            "catalogue_version",
            "verdict",
            name="pk_discovery_road_ratings",
        ),
    )
    # The review process reads by source feature: the catalogue's own IDs are
    # content hashes that move with every OSM extract, so a rating is joined back
    # on the stable upstream key.
    op.create_index(
        "ix_discovery_road_ratings_source",
        "discovery_road_ratings",
        ["source_feature_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_discovery_road_ratings_source",
        table_name="discovery_road_ratings",
    )
    op.drop_table("discovery_road_ratings")
