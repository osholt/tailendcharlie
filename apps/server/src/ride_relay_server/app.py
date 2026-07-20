from __future__ import annotations

import hmac
import json
import time
from collections.abc import Callable
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import JSONResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Histogram,
    generate_latest,
)
from pydantic import ValidationError
from sqlalchemy import text
from sqlalchemy.orm import Session

from .config import Settings, get_settings
from .crypto import CursorCodec, DataCipher, base64url, sha256, token_hash
from .database import (
    create_database_engine,
    create_session_factory,
    initialize_schema,
    session_dependency,
)
from .rate_limit import SlidingWindowRateLimiter
from .schemas import JoinCodeResponse, RegisterJoinCodeRequest, SyncRequest
from .service import RelayService, RelayServiceError


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    engine = create_database_engine(settings)
    session_factory = create_session_factory(engine)
    cipher = DataCipher(settings.decoded_key("data_encryption_key"))
    service = RelayService(
        settings,
        cipher,
        CursorCodec(settings.decoded_key("cursor_signing_key")),
    )
    limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.rate_limit_requests,
        window_seconds=settings.rate_limit_window_seconds,
    )
    join_code_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.join_code_lookup_rate_limit_requests,
        window_seconds=settings.join_code_lookup_rate_limit_window_seconds,
    )
    # A tighter, IP-independent cap on token-less lookups: the six-digit code
    # alone is brute-forceable across many source IPs, so the global window
    # bounds the whole keyspace's guess rate regardless of IP diversity.
    # Requests carrying a valid resolve token skip this cap entirely - they
    # are protected cryptographically rather than by rate.
    join_code_global_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.join_code_global_rate_limit_requests,
        window_seconds=settings.join_code_lookup_rate_limit_window_seconds,
        maximum_keys=1,
    )
    registry = CollectorRegistry()
    sync_requests = Counter(
        "ride_relay_sync_requests_total",
        "Internet relay synchronization requests",
        ("outcome",),
        registry=registry,
    )
    sync_duration = Histogram(
        "ride_relay_sync_duration_seconds",
        "Internet relay synchronization duration",
        registry=registry,
    )
    join_code_requests = Counter(
        "ride_relay_join_code_requests_total",
        "Six-digit ride-code lookup requests",
        ("outcome",),
        registry=registry,
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if settings.auto_create_schema:
            initialize_schema(engine)
        yield
        engine.dispose()

    app = FastAPI(
        title="Tail End Charlie Server",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.trusted_hosts)
    app.state.settings = settings
    app.state.engine = engine
    app.state.session_factory = session_factory

    def database_session():
        yield from session_dependency(session_factory)

    @app.middleware("http")
    async def security_headers(request: Request, call_next: Callable):
        response = await call_next(request)
        response.headers["cache-control"] = "no-store"
        response.headers["x-content-type-options"] = "nosniff"
        response.headers["x-frame-options"] = "DENY"
        response.headers["referrer-policy"] = "no-referrer"
        return response

    @app.exception_handler(RelayServiceError)
    async def relay_error_handler(_: Request, error: RelayServiceError) -> JSONResponse:
        sync_requests.labels(outcome=f"http_{error.status_code}").inc()
        return JSONResponse(
            status_code=error.status_code,
            content={"error": error.message},
        )

    @app.exception_handler(RequestValidationError)
    async def request_validation_handler(_: Request, __: RequestValidationError) -> JSONResponse:
        return JSONResponse(status_code=400, content={"error": "Malformed request"})

    @app.get("/health/live", include_in_schema=False)
    def live() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/health/ready", include_in_schema=False)
    def ready(session: Session = Depends(database_session)) -> dict[str, str]:
        session.execute(text("SELECT 1"))
        return {"status": "ready"}

    @app.get("/metrics", include_in_schema=False)
    def metrics() -> Response:
        return Response(content=generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    def _join_code_rate_limit_response(retry_after: int) -> Response:
        join_code_requests.labels(outcome="rate_limited").inc()
        return JSONResponse(
            status_code=429,
            headers={"retry-after": str(min(retry_after, 300))},
            content={"error": "Ride-code lookup rate limit exceeded"},
        )

    def join_code_rate_limit(request: Request) -> Response | None:
        client_ip = request.client.host if request.client is not None else "unknown"
        retry_after = join_code_limiter.check(f"join-code-ip:{client_ip}")
        if retry_after is None:
            return None
        return _join_code_rate_limit_response(retry_after)

    @app.put("/api/v1/join-codes/{ride_code}", include_in_schema=False)
    def register_join_code(
        ride_code: str,
        payload: RegisterJoinCodeRequest,
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        authorization = request.headers.get("authorization", "")
        if not authorization.startswith("Bearer "):
            raise RelayServiceError(401, "Ride credential required")
        service.register_join_code(
            session,
            ride_code=ride_code,
            ride_id=payload.rideId,
            invite_secret=payload.inviteSecret,
            bearer_token=authorization[7:],
            resolve_token=payload.resolveToken,
        )
        join_code_requests.labels(outcome="registered").inc()
        return Response(status_code=204)

    @app.get(
        "/api/v1/join-codes/{ride_code}",
        include_in_schema=False,
        response_model=None,
    )
    def resolve_join_code(
        ride_code: str,
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        if len(ride_code) != 6 or not ride_code.isascii() or not ride_code.isdecimal():
            raise RelayServiceError(400, "Ride code must be six digits")
        resolve_token = request.headers.get("x-ride-relay-join-token") or None
        if limited := join_code_rate_limit(request):
            return limited
        if resolve_token is None:
            retry_after = join_code_global_limiter.check("join-code-global")
            if retry_after is not None:
                return _join_code_rate_limit_response(retry_after)
        result = service.resolve_join_code(
            session,
            ride_code=ride_code,
            resolve_token=resolve_token,
        )
        join_code_requests.labels(outcome="resolved").inc()
        return JSONResponse(content=JoinCodeResponse.model_validate(result).model_dump())

    @app.post("/api/v1/rides/{ride_id}/events:sync", include_in_schema=False)
    async def synchronize(
        ride_id: str,
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        started = time.monotonic()
        content_length = request.headers.get("content-length")
        if content_length is not None:
            try:
                if int(content_length) > settings.maximum_request_bytes:
                    raise RelayServiceError(413, "Sync request exceeds size limit")
            except ValueError as error:
                raise RelayServiceError(400, "Invalid content length") from error
        chunks = bytearray()
        async for chunk in request.stream():
            if len(chunks) + len(chunk) > settings.maximum_request_bytes:
                raise RelayServiceError(413, "Sync request exceeds size limit")
            chunks.extend(chunk)
        body = bytes(chunks)
        if "application/json" not in request.headers.get("content-type", "").lower():
            raise RelayServiceError(400, "Content type must be application/json")

        authorization = request.headers.get("authorization", "")
        if not authorization.startswith("Bearer "):
            raise RelayServiceError(401, "Ride credential required")
        bearer_token = authorization[7:]
        idempotency_key = request.headers.get("idempotency-key", "")
        expected_key = f"rr1-{base64url(sha256(body))}"
        if not hmac.compare_digest(idempotency_key, expected_key):
            raise RelayServiceError(400, "Idempotency key does not match request")
        device_header = request.headers.get("x-ride-relay-device", "")

        client_ip = request.client.host if request.client is not None else "unknown"
        retry_after = limiter.check(f"ip:{client_ip}")
        if retry_after is None:
            retry_after = limiter.check(f"token:{token_hash(bearer_token).hex()}")
        if retry_after is not None:
            sync_requests.labels(outcome="rate_limited").inc()
            return JSONResponse(
                status_code=429,
                headers={"retry-after": str(min(retry_after, 300))},
                content={"error": "Rate limit exceeded"},
            )

        try:
            parsed = SyncRequest.model_validate_json(body)
        except (ValidationError, json.JSONDecodeError, UnicodeDecodeError) as error:
            raise RelayServiceError(400, "Malformed sync request") from error

        try:
            result = service.synchronize(
                session,
                ride_id=ride_id,
                bearer_token=bearer_token,
                idempotency_key=idempotency_key,
                request_hash=sha256(body),
                device_header=device_header,
                request=parsed,
            )
        except RelayServiceError:
            raise
        except Exception as error:
            session.rollback()
            sync_requests.labels(outcome="internal_error").inc()
            if settings.environment == "test":
                raise
            raise RelayServiceError(500, "Internet relay temporarily unavailable") from error
        finally:
            sync_duration.observe(time.monotonic() - started)

        encoded = json.dumps(result, separators=(",", ":"), allow_nan=False).encode()
        if len(encoded) > settings.maximum_response_bytes:
            raise RelayServiceError(500, "Relay response exceeded its safety limit")
        sync_requests.labels(outcome="success").inc()
        return Response(content=encoded, media_type="application/json")

    return app


def default_app() -> FastAPI:
    return create_app()
