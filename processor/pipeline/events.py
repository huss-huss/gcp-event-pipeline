"""Translate incoming CloudEvents into a reference to the raw object to process.

Three delivery shapes are accepted so the same code runs under every supported
trigger:

1. Pub/Sub push subscription -> function URL. functions-framework converts the
   raw push body into a ``google.cloud.pubsub.topic.v1.messagePublished``
   CloudEvent whose ``data.message`` carries the GCS notification.
2. Eventarc trigger on the notification topic (same CloudEvent type/shape).
3. Eventarc direct Cloud Storage trigger
   (``google.cloud.storage.object.v1.finalized``), data = object resource.
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

PUBSUB_EVENT_TYPE = "google.cloud.pubsub.topic.v1.messagePublished"
GCS_FINALIZED_EVENT_TYPE = "google.cloud.storage.object.v1.finalized"


class InvalidEventError(ValueError):
    """The event cannot be processed and must not be retried."""


@dataclass(frozen=True)
class ObjectRef:
    bucket: str
    name: str
    generation: int
    time_created: datetime
    size: int | None = None

    @property
    def uri(self) -> str:
        return f"gs://{self.bucket}/{self.name}#{self.generation}"


@dataclass(frozen=True)
class ParsedEvent:
    """``ref`` is None when the event is valid but not actionable (e.g. a delete notification)."""

    ref: ObjectRef | None
    reason: str = ""


def parse_cloud_event(event_type: str, data: Any) -> ParsedEvent:
    if not isinstance(data, dict):
        raise InvalidEventError("event data is not a JSON object")
    if event_type == PUBSUB_EVENT_TYPE:
        return _from_pubsub(data)
    if event_type == GCS_FINALIZED_EVENT_TYPE:
        return ParsedEvent(_from_object_resource(data))
    raise InvalidEventError(f"unsupported event type: {event_type!r}")


def _from_pubsub(data: dict[str, Any]) -> ParsedEvent:
    message = data.get("message")
    if not isinstance(message, dict):
        raise InvalidEventError("Pub/Sub event has no message")
    attributes = message.get("attributes") or {}
    notification_type = attributes.get("eventType")
    if notification_type != "OBJECT_FINALIZE":
        return ParsedEvent(None, f"ignored notification type {notification_type!r}")
    if attributes.get("payloadFormat") != "JSON_API_V1":
        raise InvalidEventError("notification payloadFormat must be JSON_API_V1")
    try:
        resource = json.loads(base64.b64decode(message.get("data") or "", validate=True))
    except (ValueError, TypeError) as exc:
        raise InvalidEventError(f"notification payload is not base64 JSON: {exc}") from exc
    if not isinstance(resource, dict):
        raise InvalidEventError("notification payload is not a JSON object")
    ref = _from_object_resource(resource)
    # Attributes are authoritative for identity; cross-check to catch tampering/bugs.
    if attributes.get("objectGeneration") and int(attributes["objectGeneration"]) != ref.generation:
        raise InvalidEventError("objectGeneration attribute does not match payload")
    return ParsedEvent(ref)


def _from_object_resource(resource: dict[str, Any]) -> ObjectRef:
    try:
        bucket = str(resource["bucket"])
        name = str(resource["name"])
        generation = int(resource["generation"])
        time_created = _parse_ts(str(resource["timeCreated"]))
    except (KeyError, ValueError, TypeError) as exc:
        raise InvalidEventError(f"object resource missing/invalid field: {exc}") from exc
    if not bucket or not name:
        raise InvalidEventError("bucket and name must be non-empty")
    size = resource.get("size")
    return ObjectRef(
        bucket=bucket,
        name=name,
        generation=generation,
        time_created=time_created,
        size=int(size) if size is not None else None,
    )


def _parse_ts(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must be timezone-aware")
    return parsed.astimezone(UTC)
