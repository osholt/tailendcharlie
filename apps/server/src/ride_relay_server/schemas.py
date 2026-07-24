from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, Literal

from pydantic import (
    AnyHttpUrl,
    BaseModel,
    ConfigDict,
    Field,
    field_validator,
    model_validator,
)


class SyncRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    protocolVersion: Literal[1]
    deviceId: str = Field(min_length=1, max_length=128)
    cursor: str | None = Field(default=None, max_length=512)
    events: list[dict[str, Any]]


class SyncResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    protocolVersion: Literal[1] = 1
    cursor: str
    acceptedEventIds: list[str]
    events: list[dict[str, Any]]


class PresencePoint(BaseModel):
    model_config = ConfigDict(extra="forbid")

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class PresenceLocationSample(BaseModel):
    model_config = ConfigDict(extra="forbid")

    position: PresencePoint
    recordedAt: datetime
    accuracyMeters: float = Field(ge=0, le=500)
    speedMetersPerSecond: float | None = Field(default=None, ge=0, le=100)
    headingDegrees: float | None = Field(default=None, ge=0, lt=360)


class PresencePositionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    displayName: str = Field(min_length=1, max_length=80)
    role: Literal["lead", "rider", "tailEndCharlie", "marker"]
    motorcycleStyle: str = Field(min_length=1, max_length=40)
    riderColor: str = Field(min_length=1, max_length=40)
    sample: PresenceLocationSample


class PresenceSyncRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    protocolVersion: Literal[1]
    deviceId: str = Field(min_length=1, max_length=128)
    position: PresencePositionRequest | None = None
    clear: bool = False

    @model_validator(mode="after")
    def clear_cannot_publish(self) -> PresenceSyncRequest:
        if self.clear and self.position is not None:
            raise ValueError("A presence request cannot publish and clear together")
        return self


class PresencePositionResponse(PresencePositionRequest):
    riderId: str
    receivedAt: datetime
    expiresAt: datetime


class PresenceSyncResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    protocolVersion: Literal[1] = 1
    ttlSeconds: int
    positions: list[PresencePositionResponse]


class PushPreferences(BaseModel):
    model_config = ConfigDict(extra="forbid")

    safety: bool = True
    status: bool = True
    administrative: bool = True


class PushRegistrationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    platform: Literal["ios", "android"]
    provider: Literal["apns", "fcm"]
    token: str = Field(min_length=16, max_length=4096)
    role: Literal["lead", "rider", "tailEndCharlie", "marker"]
    preferences: PushPreferences = Field(default_factory=PushPreferences)

    @model_validator(mode="after")
    def provider_matches_platform(self) -> PushRegistrationRequest:
        if self.platform == "ios" and self.provider != "apns":
            raise ValueError("iOS registrations must use APNs")
        if self.platform == "android" and self.provider != "fcm":
            raise ValueError("Android registrations must use FCM")
        return self


class PushRegistrationResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    installationId: str
    platform: Literal["ios", "android"]
    provider: Literal["apns", "fcm"]
    role: Literal["lead", "rider", "tailEndCharlie", "marker"]
    preferences: PushPreferences
    registeredAt: datetime
    updatedAt: datetime


class RegisterJoinCodeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    rideId: str = Field(min_length=1, max_length=128)
    inviteSecret: str = Field(min_length=16, max_length=512)
    resolveToken: str = Field(min_length=16, max_length=128)


class JoinCodeResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    rideId: str
    rideCode: str
    inviteSecret: str
    resolveToken: str


class CompatibilityResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    serverProtocol: int
    minimumClientProtocol: int
    maximumClientProtocol: int
    capabilities: list[str]
    requiredCapabilities: list[str]
    cacheSeconds: int
    updateUrls: dict[str, str]


DiscoveryCategory = Literal[
    "twisty_highlight",
    "mountain_pass",
    "good_biking_road",
    "biker_stop",
]


class DiscoveryGeometry(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["Point", "LineString"]
    coordinates: Any

    @model_validator(mode="after")
    def validate_coordinates(self) -> DiscoveryGeometry:
        points = [self.coordinates] if self.type == "Point" else self.coordinates
        if not isinstance(points, list) or not points or len(points) > 200:
            raise ValueError("Geometry must contain between 1 and 200 points")
        if self.type == "LineString" and len(points) < 2:
            raise ValueError("LineString geometry requires at least two points")
        for point in points:
            if (
                not isinstance(point, list)
                or len(point) != 2
                or not all(isinstance(value, int | float) for value in point)
                or not -180 <= point[0] <= 180
                or not -90 <= point[1] <= 90
            ):
                raise ValueError("Invalid GeoJSON coordinate")
        return self


class DiscoverySuggestionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    clientSubmissionId: str = Field(min_length=1, max_length=128)
    category: DiscoveryCategory
    action: Literal["add", "correct", "remove"] = "add"
    targetFeatureId: str | None = Field(default=None, min_length=1, max_length=128)
    name: str = Field(min_length=1, max_length=120)
    reason: str = Field(min_length=5, max_length=500)
    evidenceUrl: AnyHttpUrl | None = None
    geometry: DiscoveryGeometry
    createdAt: datetime

    @model_validator(mode="after")
    def require_target_for_revision(self) -> DiscoverySuggestionRequest:
        if self.action != "add" and not self.targetFeatureId:
            raise ValueError("Corrections and removals require a target feature")
        return self


class DiscoveryModerationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    action: Literal["approve", "reject", "request_changes", "supersede"]
    reason: str = Field(min_length=3, max_length=500)


class CreatePlanRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str | None = Field(default=None, max_length=200)
    gpx: str = Field(min_length=1)


class CreatePlanResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str
    expiresAt: str


class GetPlanResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str
    name: str | None
    gpx: str
    createdAt: str
    expiresAt: str


class CreateObserverGrantRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: str = Field(min_length=1, max_length=80)
    durationMinutes: int = Field(ge=30, le=24 * 60)
    consentConfirmed: Literal[True]


class ObserverGrantResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    label: str
    createdAt: datetime
    expiresAt: datetime
    revokedAt: datetime | None


class CreateObserverGrantResponse(ObserverGrantResponse):
    managementToken: str
    publisherToken: str
    observerToken: str


class ObserverPosition(BaseModel):
    model_config = ConfigDict(extra="forbid")

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    accuracyMeters: float = Field(ge=0, le=500)
    recordedAt: datetime

    @field_validator("recordedAt")
    @classmethod
    def recorded_at_requires_timezone(cls, value: datetime) -> datetime:
        return _aware_utc(value)


class PublishObserverAssistance(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["assistance", "emergencyStop"]
    reportedAt: datetime

    @field_validator("reportedAt")
    @classmethod
    def reported_at_requires_timezone(cls, value: datetime) -> datetime:
        return _aware_utc(value)


class PublishObserverSnapshotRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    subjectName: str = Field(min_length=1, max_length=80)
    snapshotGeneratedAt: datetime
    rideStatus: Literal["waiting", "active", "paused", "ended"]
    statusUpdatedAt: datetime
    position: ObserverPosition | None
    assistanceUpdatedAt: datetime
    assistance: PublishObserverAssistance | None

    @field_validator(
        "snapshotGeneratedAt",
        "statusUpdatedAt",
        "assistanceUpdatedAt",
    )
    @classmethod
    def timestamps_require_timezone(cls, value: datetime) -> datetime:
        return _aware_utc(value)


class ObserverAssistance(PublishObserverAssistance):
    label: str


class ObserverSnapshotResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    protocolVersion: Literal[1] = 1
    label: str
    subjectName: str | None
    rideStatus: Literal["waiting", "active", "paused", "ended"]
    statusUpdatedAt: datetime | None
    freshness: Literal["unavailable", "fresh", "delayed", "offline"]
    serverTime: datetime
    expiresAt: datetime
    position: ObserverPosition | None
    assistance: ObserverAssistance | None


def _aware_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("Timestamp timezone is required")
    return value.astimezone(UTC)
