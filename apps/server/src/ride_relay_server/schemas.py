from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field, model_validator


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
