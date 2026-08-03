FROM ghcr.io/astral-sh/uv:0.11.16 AS uv

FROM python:3.12-slim AS runtime

ARG RIDE_RELAY_BUILD_COMMIT=unknown
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    RIDE_RELAY_BUILD_COMMIT=${RIDE_RELAY_BUILD_COMMIT}

WORKDIR /app
COPY --from=uv /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock README.md alembic.ini ./
COPY alembic ./alembic
COPY src ./src
RUN uv sync --frozen --no-dev

RUN useradd --create-home --uid 10001 ride-relay
USER ride-relay

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health/live', timeout=2)"]

CMD ["sh", "-c", ".venv/bin/alembic upgrade head && exec .venv/bin/ride-relay-server"]
