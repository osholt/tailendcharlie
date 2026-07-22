from __future__ import annotations

from datetime import datetime

from sqlalchemy import (
    JSON,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class Ride(Base):
    __tablename__ = "rides"

    id: Mapped[str] = mapped_column(String(128), primary_key=True)
    token_hash: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    delete_after: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    events: Mapped[list[StoredEvent]] = relationship(
        back_populates="ride",
        cascade="all, delete-orphan",
    )
    replays: Mapped[list[IdempotencyReplay]] = relationship(
        back_populates="ride",
        cascade="all, delete-orphan",
    )


class RideJoinCode(Base):
    """A short-lived, encrypted lookup record for a six-digit ride code."""

    __tablename__ = "ride_join_codes"
    __table_args__ = (Index("ix_ride_join_codes_expiry", "expires_at"),)

    code: Mapped[str] = mapped_column(String(6), primary_key=True)
    ride_id: Mapped[str] = mapped_column(String(128), nullable=False)
    token_hash: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    secret_ciphertext: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class RidePlan(Base):
    """An encrypted, pre-ride GPX route behind a short lookup code.

    Unrelated to the live ride/join-code tables: a plan never carries a ride
    secret and a fetched plan never claims a ride. The phone that loads one
    still runs its own unchanged create-ride flow.
    """

    __tablename__ = "ride_plans"
    __table_args__ = (Index("ix_ride_plans_expiry", "expires_at"),)

    code: Mapped[str] = mapped_column(String(16), primary_key=True)
    name: Mapped[str | None] = mapped_column(String(200))
    gpx_ciphertext: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class StoredEvent(Base):
    __tablename__ = "ride_events"
    __table_args__ = (
        UniqueConstraint("ride_id", "event_id", name="uq_ride_event_identity"),
        Index("ix_ride_events_cursor", "ride_id", "sequence"),
        Index("ix_ride_events_expiry", "expires_at"),
    )

    sequence: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    ride_id: Mapped[str] = mapped_column(
        String(128),
        ForeignKey("rides.id", ondelete="CASCADE"),
        nullable=False,
    )
    event_id: Mapped[str] = mapped_column(String(128), nullable=False)
    device_id: Mapped[str] = mapped_column(String(128), nullable=False)
    event_type: Mapped[str] = mapped_column(String(48), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    body_hash: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    body_ciphertext: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)

    ride: Mapped[Ride] = relationship(back_populates="events")


class IdempotencyReplay(Base):
    __tablename__ = "idempotency_replays"
    __table_args__ = (
        UniqueConstraint("ride_id", "idempotency_key", name="uq_ride_idempotency_key"),
        Index("ix_idempotency_replays_expiry", "expires_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    ride_id: Mapped[str] = mapped_column(
        String(128),
        ForeignKey("rides.id", ondelete="CASCADE"),
        nullable=False,
    )
    idempotency_key: Mapped[str] = mapped_column(String(64), nullable=False)
    request_hash: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    response_ciphertext: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

    ride: Mapped[Ride] = relationship(back_populates="replays")


class DiscoverySuggestion(Base):
    """Private rider input; never queried by the public layer endpoint."""

    __tablename__ = "discovery_suggestions"
    __table_args__ = (
        UniqueConstraint(
            "client_submission_id",
            name="uq_discovery_suggestion_client_submission",
        ),
        Index("ix_discovery_suggestions_status", "status", "submitted_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    client_submission_id: Mapped[str] = mapped_column(String(128), nullable=False)
    request_hash: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    category: Mapped[str] = mapped_column(String(32), nullable=False)
    action: Mapped[str] = mapped_column(String(16), nullable=False)
    target_feature_id: Mapped[str | None] = mapped_column(String(128))
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    evidence_url: Mapped[str | None] = mapped_column(String(500))
    geometry_json: Mapped[dict] = mapped_column(JSON, nullable=False)
    status: Mapped[str] = mapped_column(String(24), nullable=False)
    submitted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    reviewer: Mapped[str | None] = mapped_column(String(120))
    moderation_reason: Mapped[str | None] = mapped_column(Text)
    published_feature_id: Mapped[str | None] = mapped_column(String(128))

    audit_events: Mapped[list[DiscoveryModerationEvent]] = relationship(
        back_populates="suggestion",
        cascade="all, delete-orphan",
    )


class DiscoveryModerationEvent(Base):
    __tablename__ = "discovery_moderation_events"
    __table_args__ = (Index("ix_discovery_moderation_suggestion", "suggestion_id", "created_at"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    suggestion_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("discovery_suggestions.id", ondelete="CASCADE"),
        nullable=False,
    )
    action: Mapped[str] = mapped_column(String(24), nullable=False)
    actor: Mapped[str] = mapped_column(String(120), nullable=False)
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

    suggestion: Mapped[DiscoverySuggestion] = relationship(
        back_populates="audit_events",
    )


class DiscoveryFeature(Base):
    """Approved catalogue revisions and takedowns exposed to public clients."""

    __tablename__ = "discovery_features"
    __table_args__ = (Index("ix_discovery_features_public", "status", "category"),)

    id: Mapped[str] = mapped_column(String(128), primary_key=True)
    category: Mapped[str] = mapped_column(String(32), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    geometry_json: Mapped[dict] = mapped_column(JSON, nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    confidence: Mapped[str] = mapped_column(String(16), nullable=False)
    source_name: Mapped[str] = mapped_column(String(120), nullable=False)
    source_feature_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_url: Mapped[str | None] = mapped_column(String(500))
    warning: Mapped[str] = mapped_column(Text, nullable=False)
    approved_revision_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("discovery_suggestions.id"),
        nullable=False,
    )
    last_verified_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
