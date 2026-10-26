"""Contract tests for the Cloud Storage adapter using a mocked client (no network)."""

from __future__ import annotations

import io
from unittest import mock

import pytest
from google.api_core import exceptions as gexc

from pipeline.gcs import CHUNK_SIZE, GcsObjectStore
from pipeline.storage import ObjectAlreadyExistsError, ObjectNotFoundError


@pytest.fixture
def client():
    return mock.MagicMock(name="storage.Client")


def blob_of(client):
    return client.bucket.return_value.blob.return_value


def test_iter_lines_reads_requested_generation_in_chunks(client):
    blob_of(client).open.return_value = io.BytesIO(b"a\nb\n")
    lines = list(GcsObjectStore(client).iter_lines("raw", "incoming/x.jsonl", 42))
    assert lines == [b"a\n", b"b\n"]
    client.bucket.assert_called_with("raw")
    client.bucket.return_value.blob.assert_called_with("incoming/x.jsonl", generation=42)
    blob_of(client).open.assert_called_with("rb", chunk_size=CHUNK_SIZE)


def test_iter_lines_maps_not_found(client):
    blob_of(client).open.side_effect = gexc.NotFound("gone")
    with pytest.raises(ObjectNotFoundError):
        list(GcsObjectStore(client).iter_lines("raw", "x", 1))


def test_writer_is_create_only_and_commits_on_close(client):
    writer = blob_of(client).open.return_value
    with GcsObjectStore(client).create_writer("cur", "out.jsonl", "application/x-ndjson") as w:
        w.write(b"{}\n")
    blob_of(client).open.assert_called_with(
        "wb", content_type="application/x-ndjson", if_generation_match=0, ignore_flush=True
    )
    writer.write.assert_called_once_with(b"{}\n")
    writer.close.assert_called_once()
    writer.terminate.assert_not_called()


def test_writer_maps_precondition_failure_on_commit(client):
    blob_of(client).open.return_value.close.side_effect = gexc.PreconditionFailed("exists")
    with pytest.raises(ObjectAlreadyExistsError), GcsObjectStore(client).create_writer("cur", "o", "t") as w:
        w.write(b"x")


def test_writer_maps_precondition_failure_on_early_chunk_upload(client):
    blob_of(client).open.return_value.write.side_effect = gexc.PreconditionFailed("exists")
    with pytest.raises(ObjectAlreadyExistsError), GcsObjectStore(client).create_writer("cur", "o", "t") as w:
        w.write(b"x" * 10)
    blob_of(client).open.return_value.terminate.assert_called_once()


def test_writer_aborts_upload_when_processing_fails(client):
    writer = blob_of(client).open.return_value

    def process():
        with GcsObjectStore(client).create_writer("cur", "o", "t") as w:
            w.write(b"partial")
            raise RuntimeError("boom")

    with pytest.raises(RuntimeError):
        process()
    writer.terminate.assert_called_once()
    writer.close.assert_not_called()
