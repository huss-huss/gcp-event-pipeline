"""Transport-agnostic CloudEvent handling and error classification.

Return normally  -> 2xx -> message acknowledged.
Raise            -> 5xx -> Pub/Sub redelivers with exponential backoff and,
                    after max delivery attempts, dead-letters the message.

Only *transient* failures (storage/network errors) are raised. Events that can
never succeed (unparseable, wrong type) are logged at ERROR and acknowledged so
they do not burn retries; the log-based failure metric alerts on them.
"""

from __future__ import annotations

import logging
from typing import Any

from pipeline.events import InvalidEventError, parse_cloud_event
from pipeline.processor import Processor, ProcessResult

logger = logging.getLogger("pipeline.handler")


def handle_event(event_id: str, event_type: str, data: Any, processor: Processor) -> ProcessResult | None:
    ctx = {"cloud_event_id": event_id, "cloud_event_type": event_type}
    try:
        parsed = parse_cloud_event(event_type, data)
    except InvalidEventError as exc:
        logger.error("rejected invalid event", extra={"event": "invalid_event", "error": str(exc), **ctx})
        return None
    if parsed.ref is None:
        logger.info("ignored event", extra={"event": "event_ignored", "reason": parsed.reason, **ctx})
        return None
    try:
        return processor.process(parsed.ref)
    except Exception:
        logger.exception(
            "processing failed; event will be retried",
            extra={"event": "processing_failed", "source": parsed.ref.uri, **ctx},
        )
        raise
