from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

import pytest
from functions_framework import create_app

from pipeline.events import GCS_FINALIZED_EVENT_TYPE, PUBSUB_EVENT_TYPE, InvalidEventError, parse_cloud_event
from pipeline.handler import handle_event
from pipeline.processor import output_paths
from tests.conftest import CURATED_BUCKET, gcs_notification, order

MAIN = Path(__file__).resolve().parents[1] / "main.py"


def test_parse_pubsub_notification(upload):
    ref = upload("incoming/a.jsonl", b"{}")
    parsed = parse_cloud_event(PUBSUB_EVENT_TYPE, gcs_notification(ref))
    assert parsed.ref == ref


def test_parse_direct_storage_event(upload):
    ref = upload("incoming/a.jsonl", b"{}")
    data = {
        "bucket": ref.bucket,
        "name": ref.name,
        "generation": str(ref.generation),
        "timeCreated": "2026-10-26T08:30:00.000Z",
        "size": "2",
    }
    assert parse_cloud_event(GCS_FINALIZED_EVENT_TYPE, data).ref == ref


def test_non_finalize_notifications_are_ignored(upload):
    ref = upload("incoming/a.jsonl", b"{}")
    parsed = parse_cloud_event(PUBSUB_EVENT_TYPE, gcs_notification(ref, event_type="OBJECT_DELETE"))
    assert parsed.ref is None


@pytest.mark.parametrize(
    "mutate",
    [
        lambda b: b["message"].update(data="%%%not-base64"),
        lambda b: b["message"].update(data=base64.b64encode(b"[]").decode()),
        lambda b: b["message"]["attributes"].update(objectGeneration="1"),
        lambda b: b["message"]["attributes"].update(payloadFormat="NONE"),
        lambda b: b.pop("message"),
    ],
)
def test_invalid_notifications_raise(upload, mutate):
    body = gcs_notification(upload("incoming/a.jsonl", b"{}"))
    mutate(body)
    with pytest.raises(InvalidEventError):
        parse_cloud_event(PUBSUB_EVENT_TYPE, body)


def test_handler_acks_invalid_event_and_logs_error(processor, caplog):
    assert handle_event("id-1", "google.cloud.audit.log.v1.written", {}, processor) is None
    record = next(r for r in caplog.records if getattr(r, "event", None) == "invalid_event")
    assert record.levelname == "ERROR"


def test_handler_reraises_transient_errors(processor, store, upload):
    ref = upload("incoming/a.jsonl", json.dumps(order()).encode())
    store.fail_reads_with = ConnectionError("reset by peer")
    with pytest.raises(ConnectionError):
        handle_event("id-1", PUBSUB_EVENT_TYPE, gcs_notification(ref), processor)


@pytest.fixture
def client(monkeypatch, processor):
    monkeypatch.setenv("CURATED_BUCKET", CURATED_BUCKET)
    app = create_app(target="process_raw_object", source=str(MAIN), signature_type="cloudevent")
    monkeypatch.setattr(sys.modules["main"], "_processor", lambda: processor)
    return app.test_client()


def test_pubsub_push_request_end_to_end(client, store, upload, processor):
    """A raw Pub/Sub push body (what our push subscription sends) is processed."""
    ref = upload("incoming/a.jsonl", json.dumps(order()).encode())
    response = client.post("/", json=gcs_notification(ref))
    assert response.status_code == 200
    assert store.names(CURATED_BUCKET) == [output_paths(ref, processor._settings).curated]


def test_eventarc_binary_cloudevent_end_to_end(client, store, upload, processor):
    """The same message delivered by an Eventarc Pub/Sub trigger (binary-mode CloudEvent)."""
    ref = upload("incoming/a.jsonl", json.dumps(order()).encode())
    body = gcs_notification(ref)
    headers = {
        "ce-id": "1234567890",
        "ce-specversion": "1.0",
        "ce-type": PUBSUB_EVENT_TYPE,
        "ce-source": "//pubsub.googleapis.com/projects/demo/topics/raw-object-events",
        "Content-Type": "application/json",
    }
    response = client.post("/", headers=headers, data=json.dumps({"message": body["message"]}))
    assert response.status_code == 200
    assert store.names(CURATED_BUCKET) == [output_paths(ref, processor._settings).curated]


def test_transient_failure_returns_5xx_so_pubsub_retries(client, store, upload):
    ref = upload("incoming/a.jsonl", json.dumps(order()).encode())
    store.fail_reads_with = ConnectionError("reset by peer")
    response = client.post("/", json=gcs_notification(ref))
    assert response.status_code >= 500
