from __future__ import annotations

import logging

from .config import get_settings
from .database import create_database_engine, create_session_factory
from .service import purge_expired


def main() -> None:
    settings = get_settings()
    engine = create_database_engine(settings)
    factory = create_session_factory(engine)
    with factory() as session:
        events, replays, rides, join_codes, plans, observers = purge_expired(session)
    logging.basicConfig(level=logging.INFO)
    logging.info(
        "relay cleanup complete events=%d replays=%d rides=%d join_codes=%d "
        "plans=%d observer_grants=%d",
        events,
        replays,
        rides,
        join_codes,
        plans,
        observers,
    )
    engine.dispose()


if __name__ == "__main__":
    main()
