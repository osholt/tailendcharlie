"""Bounded proxy to the routing-host charger collector (Refs #973).

The relay never polls operators or holds their credentials. A phone can request
only a small viewport; upstream targets come from configuration, never input.
"""

import asyncio
import json

import httpx

CHARGING_CAPABILITY = "charging-status-v1"
MAX_BYTES = 2 * 1024 * 1024


async def charger_viewport(url: str, bounds: dict[str, float]) -> dict:
    async with httpx.AsyncClient(timeout=10, follow_redirects=False) as client:
        async with (
            asyncio.timeout(12),
            client.stream(
                "GET",
                url,
                params=bounds,
                headers={
                    "X-Client-Id": "tailendcharlie.app",
                    "Accept": "application/json",
                    "Accept-Encoding": "identity",
                },
            ) as response,
        ):
            response.raise_for_status()
            if response.headers.get("Content-Encoding", "identity") != "identity":
                raise ValueError("Encoded charger response")
            body = bytearray()
            async for chunk in response.aiter_bytes():
                if len(body) + len(chunk) > MAX_BYTES:
                    raise ValueError("Oversized charger response")
                body.extend(chunk)
    data = json.loads(body)
    if not isinstance(data, dict) or data.get("schemaVersion") != 1:
        raise ValueError("Unsupported charger response")
    if not isinstance(data.get("locations"), list) or len(data["locations"]) > 300:
        raise ValueError("Invalid charger locations")
    if not isinstance(data.get("sources"), list) or len(data["sources"]) > 100:
        raise ValueError("Invalid charger sources")
    return data
