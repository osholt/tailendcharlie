from __future__ import annotations

import hmac
import json
import re
import time
from collections.abc import Callable
from contextlib import asynccontextmanager

from fastapi import BackgroundTasks, Depends, FastAPI, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
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
from sqlalchemy.orm import Session, sessionmaker

from .config import Settings, get_settings
from .crypto import CursorCodec, DataCipher, base64url, sha256, token_hash
from .database import (
    create_database_engine,
    create_session_factory,
    initialize_schema,
    session_dependency,
)
from .discovery import (
    create_suggestion,
    list_suggestions,
    moderate_suggestion,
    public_feature_collection,
    purge_expired_private_suggestions,
    suggestion_json,
)
from .observer import (
    create_observer_grant,
    get_managed_observer_grant,
    grant_json,
    observer_snapshot,
    publish_observer_snapshot,
    revoke_observer_grant,
)
from .push import PushDispatcher, register_push, registration_json, revoke_push
from .rate_limit import SlidingWindowRateLimiter
from .schemas import (
    CompatibilityResponse,
    CreateObserverGrantRequest,
    CreateObserverGrantResponse,
    CreatePlanRequest,
    CreatePlanResponse,
    DiscoveryModerationRequest,
    DiscoverySuggestionRequest,
    GetPlanResponse,
    JoinCodeResponse,
    ObserverGrantResponse,
    ObserverSnapshotResponse,
    PresenceSyncRequest,
    PresenceSyncResponse,
    PublishObserverSnapshotRequest,
    PushRegistrationRequest,
    PushRegistrationResponse,
    RegisterJoinCodeRequest,
    SyncRequest,
)
from .service import RelayService, RelayServiceError

OBSERVER_API_TOKEN = re.compile(r"^(?:om1|op1|ro1)_[A-Za-z0-9_-]{43}$")
RIDE_API_TOKEN = re.compile(r"^rr1_[A-Za-z0-9_-]{43}$")


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
    discovery_suggestion_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.discovery_suggestion_rate_limit_requests,
        window_seconds=settings.discovery_suggestion_rate_limit_window_seconds,
    )
    plan_create_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.plan_create_rate_limit_requests,
        window_seconds=settings.plan_create_rate_limit_window_seconds,
    )
    plan_lookup_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.plan_lookup_rate_limit_requests,
        window_seconds=settings.plan_lookup_rate_limit_window_seconds,
    )
    observer_read_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.observer_read_rate_limit_requests,
        window_seconds=settings.observer_read_rate_limit_window_seconds,
    )
    observer_ip_abuse_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.observer_ip_abuse_rate_limit_requests,
        window_seconds=settings.observer_read_rate_limit_window_seconds,
    )
    observer_create_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.observer_create_rate_limit_requests,
        window_seconds=settings.observer_create_rate_limit_window_seconds,
    )
    observer_create_ip_abuse_limiter = SlidingWindowRateLimiter(
        maximum_requests=settings.observer_create_ip_abuse_rate_limit_requests,
        window_seconds=settings.observer_create_rate_limit_window_seconds,
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
    plan_requests = Counter(
        "ride_relay_plan_requests_total",
        "Pre-ride GPX plan requests",
        ("outcome",),
        registry=registry,
    )
    push_deliveries = Counter(
        "ride_relay_push_deliveries_total",
        "Best-effort push delivery outcomes without recipient or payload labels",
        ("outcome",),
        registry=registry,
    )
    push_dispatcher = PushDispatcher.from_settings(settings, cipher)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if settings.auto_create_schema:
            initialize_schema(engine)
        yield
        push_dispatcher.close()
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
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.discovery_allowed_origins,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["authorization", "content-type"],
    )
    app.state.settings = settings
    app.state.engine = engine
    app.state.session_factory = session_factory
    app.state.service = service
    app.state.push_dispatcher = push_dispatcher

    def database_session():
        yield from session_dependency(session_factory)

    @app.middleware("http")
    async def security_headers(request: Request, call_next: Callable):
        response = await call_next(request)
        response.headers["cache-control"] = (
            "public, max-age=300, stale-while-revalidate=900"
            if request.method == "GET" and request.url.path == "/api/v1/discovery/features"
            else "no-store"
        )
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

    @app.get("/api/v1/compatibility", include_in_schema=False)
    def compatibility() -> CompatibilityResponse:
        return CompatibilityResponse(
            serverProtocol=settings.protocol_version,
            minimumClientProtocol=settings.minimum_client_protocol,
            maximumClientProtocol=settings.protocol_version,
            capabilities=sorted(set(settings.supported_capabilities)),
            requiredCapabilities=sorted(set(settings.required_capabilities)),
            cacheSeconds=settings.compatibility_cache_seconds,
            updateUrls={
                "default": settings.update_url,
                "iOS": settings.ios_update_url,
                "android": settings.android_update_url,
            },
        )

    def client_compatibility_error(request: Request, protocol: int) -> Response | None:
        platform = request.headers.get("x-tailendcharlie-platform", "")
        capabilities = {
            value.strip()
            for value in request.headers.get("x-tailendcharlie-capabilities", "").split(",")
            if value.strip()
        }
        update_url = (
            settings.ios_update_url
            if platform == "iOS"
            else settings.android_update_url
            if platform == "android"
            else settings.update_url
        )
        if protocol < settings.minimum_client_protocol:
            return JSONResponse(
                status_code=426,
                content={
                    "code": "update_required",
                    "message": "Update Tail End Charlie before joining or synchronizing.",
                    "updateUrl": update_url,
                    "minimumClientProtocol": settings.minimum_client_protocol,
                },
            )
        if protocol > settings.protocol_version:
            return JSONResponse(
                status_code=409,
                content={
                    "code": "server_upgrade_required",
                    "message": "This app is newer than the configured ride service.",
                    "serverProtocol": settings.protocol_version,
                },
            )
        missing = sorted(set(settings.required_capabilities) - capabilities)
        if missing:
            return JSONResponse(
                status_code=426,
                content={
                    "code": "update_required",
                    "message": "Update Tail End Charlie to continue safely.",
                    "updateUrl": update_url,
                    "requiredCapabilities": missing,
                },
            )
        return None

    def client_protocol(request: Request, fallback: int = 1) -> int:
        raw = request.headers.get("x-tailendcharlie-protocol")
        if raw is None:
            return fallback
        try:
            return int(raw)
        except ValueError as error:
            raise RelayServiceError(400, "Client protocol header is invalid") from error

    def require_discovery_admin(request: Request) -> None:
        configured = settings.discovery_admin_token
        if configured is None:
            raise RelayServiceError(503, "Discovery moderation is not configured")
        authorization = request.headers.get("authorization", "")
        expected = configured.get_secret_value()
        supplied = authorization[7:] if authorization.startswith("Bearer ") else ""
        if not supplied or not hmac.compare_digest(supplied, expected):
            raise RelayServiceError(401, "Discovery administrator credential required")

    @app.get("/api/v1/discovery/features", include_in_schema=False)
    def discovery_features(
        west: float = Query(ge=-180, le=180),
        south: float = Query(ge=-90, le=90),
        east: float = Query(ge=-180, le=180),
        north: float = Query(ge=-90, le=90),
        categories: str = Query(max_length=200),
        session: Session = Depends(database_session),
    ) -> JSONResponse:
        if west >= east or south >= north or east - west > 10 or north - south > 10:
            raise RelayServiceError(400, "A bounded discovery viewport is required")
        allowed = {
            "twisty_highlight",
            "mountain_pass",
            "good_biking_road",
            "biker_stop",
        }
        selected = {item for item in categories.split(",") if item in allowed}
        if not selected:
            raise RelayServiceError(400, "At least one discovery category is required")
        return JSONResponse(
            content=public_feature_collection(
                session,
                west=west,
                south=south,
                east=east,
                north=north,
                categories=selected,
            ),
            media_type="application/geo+json",
        )

    @app.post("/api/v1/discovery/suggestions", include_in_schema=False)
    def submit_discovery_suggestion(
        payload: DiscoverySuggestionRequest,
        request: Request,
        session: Session = Depends(database_session),
    ) -> JSONResponse:
        client_ip = request.client.host if request.client is not None else "unknown"
        retry_after = discovery_suggestion_limiter.check(f"suggestion:{client_ip}")
        if retry_after is not None:
            return JSONResponse(
                status_code=429,
                headers={"retry-after": str(min(retry_after, 3600))},
                content={"error": "Suggestion rate limit exceeded"},
            )
        suggestion = create_suggestion(session, payload)
        return JSONResponse(
            status_code=202,
            content=suggestion_json(suggestion, include_private=False),
        )

    @app.get("/api/v1/admin/discovery/suggestions", include_in_schema=False)
    def discovery_admin_queue(
        request: Request,
        status: str = Query(default="pending", pattern="^(pending|changes_requested)$"),
        session: Session = Depends(database_session),
    ) -> JSONResponse:
        require_discovery_admin(request)
        purge_expired_private_suggestions(
            session,
            retention_days=settings.discovery_rejected_retention_days,
        )
        suggestions = list_suggestions(session, status=status)
        return JSONResponse(
            content={
                "suggestions": [
                    suggestion_json(suggestion, include_private=True) for suggestion in suggestions
                ]
            }
        )

    @app.post(
        "/api/v1/admin/discovery/suggestions/{suggestion_id}:moderate",
        include_in_schema=False,
    )
    def discovery_admin_moderate(
        suggestion_id: str,
        payload: DiscoveryModerationRequest,
        request: Request,
        session: Session = Depends(database_session),
    ) -> JSONResponse:
        require_discovery_admin(request)
        suggestion = moderate_suggestion(
            session,
            suggestion_id,
            payload,
            reviewer=settings.discovery_admin_name,
        )
        return JSONResponse(content=suggestion_json(suggestion, include_private=True))

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
        if compatibility_error := client_compatibility_error(request, client_protocol(request)):
            return compatibility_error
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
        if compatibility_error := client_compatibility_error(request, client_protocol(request)):
            return compatibility_error
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

    def _plan_rate_limit_response(retry_after: int) -> Response:
        return JSONResponse(
            status_code=429,
            headers={"retry-after": str(min(retry_after, 300))},
            content={"error": "Plan rate limit exceeded"},
        )

    @app.post("/api/v1/plans", include_in_schema=False)
    async def create_plan(
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        content_length = request.headers.get("content-length")
        if content_length is not None:
            try:
                if int(content_length) > settings.maximum_plan_bytes:
                    raise RelayServiceError(413, "Plan upload exceeds size limit")
            except ValueError as error:
                raise RelayServiceError(400, "Invalid content length") from error
        chunks = bytearray()
        async for chunk in request.stream():
            if len(chunks) + len(chunk) > settings.maximum_plan_bytes:
                raise RelayServiceError(413, "Plan upload exceeds size limit")
            chunks.extend(chunk)
        body = bytes(chunks)
        if "application/json" not in request.headers.get("content-type", "").lower():
            raise RelayServiceError(400, "Content type must be application/json")

        client_ip = request.client.host if request.client is not None else "unknown"
        retry_after = plan_create_limiter.check(f"ip:{client_ip}")
        if retry_after is not None:
            plan_requests.labels(outcome="rate_limited").inc()
            return _plan_rate_limit_response(retry_after)

        try:
            parsed = CreatePlanRequest.model_validate_json(body)
        except (ValidationError, json.JSONDecodeError, UnicodeDecodeError) as error:
            raise RelayServiceError(400, "Malformed plan request") from error

        result = service.create_plan(session, name=parsed.name, gpx=parsed.gpx)
        plan_requests.labels(outcome="created").inc()
        return JSONResponse(content=CreatePlanResponse.model_validate(result).model_dump())

    @app.get("/api/v1/plans/{code}", include_in_schema=False, response_model=None)
    def get_plan(
        code: str,
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        client_ip = request.client.host if request.client is not None else "unknown"
        retry_after = plan_lookup_limiter.check(f"ip:{client_ip}")
        if retry_after is not None:
            plan_requests.labels(outcome="rate_limited").inc()
            return _plan_rate_limit_response(retry_after)
        result = service.get_plan(session, code=code)
        plan_requests.labels(outcome="fetched").inc()
        return JSONResponse(content=GetPlanResponse.model_validate(result).model_dump())

    @app.post(
        "/api/v1/rides/{ride_id}/observer-grants",
        include_in_schema=False,
        response_model=CreateObserverGrantResponse,
        status_code=201,
    )
    def post_observer_grant(
        ride_id: str,
        payload: CreateObserverGrantRequest,
        request: Request,
        session: Session = Depends(database_session),
    ) -> dict[str, object]:
        bearer_token = _ride_bearer(request)
        if not RIDE_API_TOKEN.fullmatch(bearer_token):
            raise RelayServiceError(401, "Ride credential rejected")
        client_ip = request.client.host if request.client is not None else "unknown"
        # Carrier-grade NAT must not make a few active rides exhaust each
        # other's normal creation allowance. The IP ceiling only bounds
        # broad abuse; each well-shaped ride secret gets the tighter budget.
        retry_after = observer_create_ip_abuse_limiter.check(f"ip:{client_ip}")
        if retry_after is None:
            retry_after = observer_create_limiter.check(
                f"ride:{sha256(bearer_token.encode()).hex()}"
            )
        if retry_after is not None:
            return JSONResponse(
                status_code=429,
                headers={"retry-after": str(min(retry_after, 3600))},
                content={"error": "Observer creation rate limit exceeded"},
            )
        grant, management_token, publisher_token, observer_token = create_observer_grant(
            session,
            settings=settings,
            ride_id=ride_id,
            bearer_token=bearer_token,
            request=payload,
        )
        return {
            **grant_json(grant),
            "managementToken": management_token,
            "publisherToken": publisher_token,
            "observerToken": observer_token,
        }

    def observer_rate_limit(request: Request, supplied_token: str) -> Response | None:
        if not OBSERVER_API_TOKEN.fullmatch(supplied_token):
            raise RelayServiceError(404, "Observer access is unavailable")
        client_ip = request.client.host if request.client is not None else "unknown"
        digest = token_hash(supplied_token).hex()
        # Valid grants get a per-secret operational budget. The much higher
        # IP budget only bounds random-token abuse and must not make riders
        # sharing carrier-grade NAT exhaust each other's normal allowance.
        retry_after = observer_ip_abuse_limiter.check(f"ip:{client_ip}")
        if retry_after is None:
            retry_after = observer_read_limiter.check(f"token:{digest}")
        if retry_after is None:
            return None
        return JSONResponse(
            status_code=429,
            headers={"retry-after": str(min(retry_after, 300))},
            content={"error": "Observer request rate limit exceeded"},
        )

    @app.get(
        "/api/v1/observer-grants/{grant_id}/management",
        include_in_schema=False,
        response_model=ObserverGrantResponse,
    )
    def get_observer_grant_management(
        grant_id: str,
        request: Request,
        session: Session = Depends(database_session),
    ) -> dict[str, object]:
        management_token = _observer_bearer(request)
        if limited := observer_rate_limit(request, management_token):
            return limited
        return grant_json(
            get_managed_observer_grant(
                session,
                grant_id=grant_id,
                management_token=management_token,
            )
        )

    @app.delete(
        "/api/v1/observer-grants/{grant_id}/management",
        include_in_schema=False,
        status_code=204,
        response_model=None,
    )
    def delete_observer_grant(
        grant_id: str,
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        management_token = _observer_bearer(request)
        if limited := observer_rate_limit(request, management_token):
            return limited
        revoke_observer_grant(
            session,
            grant_id=grant_id,
            management_token=management_token,
        )
        return Response(status_code=204)

    @app.put(
        "/api/v1/observer-grants/{grant_id}/snapshot",
        include_in_schema=False,
        status_code=204,
        response_model=None,
    )
    def put_observer_snapshot(
        grant_id: str,
        payload: PublishObserverSnapshotRequest,
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        publisher_token = _observer_bearer(request)
        if limited := observer_rate_limit(request, publisher_token):
            return limited
        publish_observer_snapshot(
            session,
            cipher=cipher,
            grant_id=grant_id,
            publisher_token=publisher_token,
            request=payload,
        )
        return Response(status_code=204)

    @app.get(
        "/api/v1/observer-grants/{grant_id}",
        include_in_schema=False,
        response_model=ObserverSnapshotResponse,
    )
    def get_observer_snapshot(
        grant_id: str,
        request: Request,
        session: Session = Depends(database_session),
    ) -> dict[str, object]:
        observer_token = _observer_bearer(request)
        if limited := observer_rate_limit(request, observer_token):
            return limited
        return observer_snapshot(
            session,
            cipher=cipher,
            grant_id=grant_id,
            observer_token=observer_token,
        )

    @app.post("/api/v1/rides/{ride_id}/events:sync", include_in_schema=False)
    async def synchronize(
        ride_id: str,
        request: Request,
        background_tasks: BackgroundTasks,
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

        request_protocol = client_protocol(request, parsed.protocolVersion)
        if compatibility_error := client_compatibility_error(request, request_protocol):
            return compatibility_error

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
        if parsed.events:
            background_tasks.add_task(
                _dispatch_push_events,
                session_factory,
                push_dispatcher,
                push_deliveries,
                ride_id,
                parsed.events,
            )
        return Response(content=encoded, media_type="application/json")

    @app.put(
        "/api/v1/rides/{ride_id}/push-registrations/{installation_id}",
        response_model=PushRegistrationResponse,
    )
    def put_push_registration(
        ride_id: str,
        installation_id: str,
        payload: PushRegistrationRequest,
        request: Request,
        session: Session = Depends(database_session),
    ) -> dict[str, object]:
        registration = register_push(
            session,
            cipher=cipher,
            ride_id=ride_id,
            bearer_token=_ride_bearer(request),
            installation_id=installation_id,
            device_header=request.headers.get("x-ride-relay-device", ""),
            request=payload,
        )
        return registration_json(registration)

    @app.delete(
        "/api/v1/rides/{ride_id}/push-registrations/{installation_id}",
        status_code=204,
        response_model=None,
    )
    def delete_push_registration(
        ride_id: str,
        installation_id: str,
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        revoke_push(
            session,
            ride_id=ride_id,
            bearer_token=_ride_bearer(request),
            installation_id=installation_id,
            device_header=request.headers.get("x-ride-relay-device", ""),
        )
        return Response(status_code=204)

    @app.post(
        "/api/v1/rides/{ride_id}/presence:sync",
        include_in_schema=False,
        response_model=None,
    )
    async def synchronize_pre_start_presence(
        ride_id: str,
        request: Request,
        session: Session = Depends(database_session),
    ) -> Response:
        content_length = request.headers.get("content-length")
        if content_length is not None:
            try:
                if int(content_length) > settings.maximum_request_bytes:
                    raise RelayServiceError(413, "Presence request exceeds size limit")
            except ValueError as error:
                raise RelayServiceError(400, "Invalid content length") from error
        chunks = bytearray()
        async for chunk in request.stream():
            if len(chunks) + len(chunk) > settings.maximum_request_bytes:
                raise RelayServiceError(413, "Presence request exceeds size limit")
            chunks.extend(chunk)
        body = bytes(chunks)
        if "application/json" not in request.headers.get("content-type", "").lower():
            raise RelayServiceError(400, "Content type must be application/json")

        authorization = request.headers.get("authorization", "")
        if not authorization.startswith("Bearer "):
            raise RelayServiceError(401, "Ride credential required")
        bearer_token = authorization[7:]
        client_ip = request.client.host if request.client is not None else "unknown"
        retry_after = limiter.check(f"ip:{client_ip}")
        if retry_after is None:
            retry_after = limiter.check(f"token:{token_hash(bearer_token).hex()}")
        if retry_after is not None:
            return JSONResponse(
                status_code=429,
                headers={"retry-after": str(min(retry_after, 300))},
                content={"error": "Rate limit exceeded"},
            )

        try:
            payload = PresenceSyncRequest.model_validate_json(body)
        except (ValidationError, json.JSONDecodeError, UnicodeDecodeError) as error:
            raise RelayServiceError(400, "Malformed presence request") from error
        request_protocol = client_protocol(request, payload.protocolVersion)
        if compatibility_error := client_compatibility_error(request, request_protocol):
            return compatibility_error
        capabilities = {
            value.strip()
            for value in request.headers.get("x-tailendcharlie-capabilities", "").split(",")
            if value.strip()
        }
        if "pre-start-presence-v1" not in capabilities:
            raise RelayServiceError(400, "Pre-start presence capability is required")
        result = service.synchronize_pre_start_presence(
            session,
            ride_id=ride_id,
            bearer_token=bearer_token,
            device_header=request.headers.get("x-ride-relay-device", ""),
            request=payload,
        )
        response = PresenceSyncResponse.model_validate(result).model_dump(mode="json")
        encoded = json.dumps(response, separators=(",", ":"), allow_nan=False).encode()
        if len(encoded) > settings.maximum_response_bytes:
            raise RelayServiceError(500, "Presence response exceeded its safety limit")
        return Response(content=encoded, media_type="application/json")

    return app


def _ride_bearer(request: Request) -> str:
    authorization = request.headers.get("authorization", "")
    if not authorization.startswith("Bearer "):
        raise RelayServiceError(401, "Ride credential required")
    return authorization[7:]


def _observer_bearer(request: Request) -> str:
    authorization = request.headers.get("authorization", "")
    if not authorization.startswith("Bearer "):
        raise RelayServiceError(404, "Observer access is unavailable")
    return authorization[7:]


def _dispatch_push_events(
    session_factory: sessionmaker[Session],
    dispatcher: PushDispatcher,
    delivery_counter: Counter,
    ride_id: str,
    events: list[dict[str, object]],
) -> None:
    with session_factory() as session:
        try:
            report = dispatcher.dispatch(session, ride_id=ride_id, events=events)
            for outcome, count in (
                ("delivered", report.delivered),
                ("failed", report.failed),
                ("not_configured", report.not_configured),
            ):
                if count:
                    delivery_counter.labels(outcome=outcome).inc(count)
        except Exception:
            # The durable event is already committed. Push is best-effort and
            # a provider failure must never turn a successful sync into data
            # loss or expose provider/token details in an API response.
            session.rollback()
            delivery_counter.labels(outcome="dispatch_error").inc()


def default_app() -> FastAPI:
    return create_app()
