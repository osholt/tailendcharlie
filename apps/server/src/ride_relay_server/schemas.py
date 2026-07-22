from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


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


class CompatibilityResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    serverProtocol: int
    minimumClientProtocol: int
    maximumClientProtocol: int
    capabilities: list[str]
    requiredCapabilities: list[str]
    cacheSeconds: int
    updateUrls: dict[str, str]
