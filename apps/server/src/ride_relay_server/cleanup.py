from __future__ import annotations

import logging

from .config import get_settings
from .database import create_database_engine, create_session_factory
from .heatmap import cleanup_heatmap, rebuild_public_snapshot
from .service import purge_expired


def main() -> None:
    settings = get_settings()
    engine = create_database_engine(settings)
    factory = create_session_factory(engine)
    with factory() as session:
        events, replays, rides, join_codes, plans, observers, pre_start_positions = purge_expired(
            session
        )
        heatmap = cleanup_heatmap(session)
        snapshot = rebuild_public_snapshot(session)
    logging.basicConfig(level=logging.INFO)
    logging.info(
        "relay cleanup complete events=%d replays=%d rides=%d join_codes=%d "
        "plans=%d observer_grants=%d pre_start_positions=%d "
        "heatmap_receipts=%d heatmap_cells=%d heatmap_contributors=%d "
        "heatmap_snapshot=%s",
        events,
        replays,
        rides,
        join_codes,
        plans,
        observers,
        pre_start_positions,
        heatmap[0],
        heatmap[1],
        heatmap[2],
        snapshot.version,
    )
    engine.dispose()


if __name__ == "__main__":
    main()
