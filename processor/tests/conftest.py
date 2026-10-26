from __future__ import annotations

import base64
import json
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

import pytest

from pipeline.config import Settings
from pipeline.events import ObjectRef
from pipeline.processor import Processor
from tests.fakes import InMemoryObjectStore

RAW_BUCKET = "acme-raw"
CURATED_BUCKET = "acme-curated"
CREATED = datetime(2026, 10, 26, 8, 30, tzinfo=UTC)


def order(**overrides: Any) -> dict[str, Any]:
    event = {
        "event_id": "evt-1",
        "event_type": "order_created",
        "order_id": "ord-1",
        "customer_id": "cus-1",
        "occurred_at": "2026-10-25T23:15:00+02:00",
        "currency": "usd",
        "items": [{"sku": "SKU-1", "quantity": 2, "unit_price": "9.99"}],
        "total_amount": "19.98",
    }
    event.update(overrides)
    return event


def jsonl(*records: Any) -> bytes:
    return b"".join((r if isinstance(r, bytes) else json.dumps(r).encode()) + b"\n" for r in records)


@pytest.fixture
def store() -> InMemoryObjectStore:
    return InMemoryObjectStore()


@pytest.fixture
def settings() -> Settings:
    return Settings(curated_bucket=CURATED_BUCKET)


@pytest.fixture
def processor(store: InMemoryObjectStore, settings: Settings) -> Processor:
    return Processor(store, settings)


@pytest.fixture
def upload(store: InMemoryObjectStore) -> Callable[[str, bytes], ObjectRef]:
    def _upload(name: str, data: bytes) -> ObjectRef:
        generation = store.put(RAW_BUCKET, name, data)
        return ObjectRef(RAW_BUCKET, name, generation, CREATED, len(data))

    return _upload


def gcs_notification(ref: ObjectRef, event_type: str = "OBJECT_FINALIZE") -> dict[str, Any]:
    """Body of a Pub/Sub push request carrying a GCS JSON_API_V1 notification."""
    resource = {
        "kind": "storage#object",
        "bucket": ref.bucket,
        "name": ref.name,
        "generation": str(ref.generation),
        "size": str(ref.size or 0),
        "timeCreated": ref.time_created.isoformat().replace("+00:00", "Z"),
        "contentType": "application/x-ndjson",
    }
    return {
        "message": {
            "attributes": {
                "bucketId": ref.bucket,
                "objectId": ref.name,
                "objectGeneration": str(ref.generation),
                "eventType": event_type,
                "payloadFormat": "JSON_API_V1",
                "notificationConfig": f"projects/_/buckets/{ref.bucket}/notificationConfigs/1",
            },
            "data": base64.b64encode(json.dumps(resource).encode()).decode(),
            "messageId": "1234567890",
            "publishTime": "2026-10-26T08:30:01.000Z",
        },
        "subscription": "projects/demo/subscriptions/raw-object-events",
        "deliveryAttempt": 1,
    }
