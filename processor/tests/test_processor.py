from __future__ import annotations

import json
from dataclasses import replace
from datetime import UTC, datetime, timedelta, timezone

import pytest

from pipeline.events import ObjectRef
from pipeline.processor import Processor, output_paths
from tests.conftest import CURATED_BUCKET, order


def read_jsonl(store, name):
    return [json.loads(line) for line in store.get(CURATED_BUCKET, name).splitlines()]


CURATED = "curated/orders/ingest_date=2026-10-26/"
QUARANTINE = "quarantine/orders/ingest_date=2026-10-26/"


def test_valid_and_invalid_records_are_split(processor, store, upload):
    ref = upload(
        "incoming/2026/10/orders.jsonl",
        b"\n".join(
            [
                json.dumps(order(event_id="e1")).encode(),
                json.dumps(order(event_id="e2", currency="eur")).encode(),
                json.dumps(order(event_id="e3", items=[])).encode(),
                b"",  # blank lines are ignored, not quarantined
                b"{not json",
            ]
        )
        + b"\n",
    )
    result = processor.process(ref)

    assert result.status == "processed"
    assert (result.lines, result.valid, result.invalid) == (5, 2, 2)
    paths = output_paths(ref, processor._settings)
    assert result.outputs == {paths.curated: "written", paths.quarantine: "written"}

    curated = read_jsonl(store, paths.curated)
    assert [r["event_id"] for r in curated] == ["e1", "e2"]
    assert curated[1]["currency"] == "EUR"
    assert curated[0]["_source"] == {
        "bucket": ref.bucket,
        "object": ref.name,
        "generation": ref.generation,
        "line": 1,
    }

    quarantined = read_jsonl(store, paths.quarantine)
    assert [(q["line"], q["reason"]) for q in quarantined] == [(3, "schema_validation"), (5, "invalid_json")]
    assert quarantined[0]["errors"][0]["loc"] == "items"
    assert quarantined[1]["raw"] == "{not json"


def test_output_paths_are_partitioned_and_derived_from_name_and_generation(upload, settings):
    ref = upload("incoming/shop eu/2026-10-26/batch 01.jsonl", b"")
    paths = output_paths(ref, settings)
    expected = f"shop_eu__2026-10-26__batch_01-g{ref.generation}.jsonl"
    assert paths.curated == CURATED + expected
    assert paths.quarantine == QUARANTINE + expected


def test_partition_uses_object_creation_date_in_utc(upload, settings):
    ref = upload("incoming/a.ndjson", b"")
    late_evening_utc_minus_5 = datetime(2026, 10, 26, 22, 0, tzinfo=timezone(timedelta(hours=-5)))
    ref = replace(ref, time_created=late_evening_utc_minus_5.astimezone(UTC))
    assert "/ingest_date=2026-10-27/" in output_paths(ref, settings).curated


def test_redelivery_is_idempotent(processor, store, upload):
    ref = upload("incoming/orders.jsonl", json.dumps(order()).encode() + b"\nnope\n")
    first = processor.process(ref)
    snapshot = {k: dict(v) for k, v in store.objects.items()}

    second = processor.process(ref)

    assert set(first.outputs.values()) == {"written"}
    assert set(second.outputs.values()) == {"already_exists"}
    assert store.objects == snapshot  # no new objects, no new generations


def test_redelivery_after_partial_commit_completes_missing_output(processor, store, upload):
    ref = upload("incoming/orders.jsonl", json.dumps(order()).encode() + b"\nnope\n")
    paths = output_paths(ref, processor._settings)
    store.fail_commit_for = {paths.quarantine}

    with pytest.raises(ConnectionError):
        processor.process(ref)
    assert store.names(CURATED_BUCKET) == [paths.curated]  # curated committed first

    store.fail_commit_for = set()
    retry = processor.process(ref)
    assert retry.outputs == {paths.curated: "already_exists", paths.quarantine: "written"}


def test_new_generation_of_same_object_produces_new_output(processor, store, upload):
    first = upload("incoming/orders.jsonl", json.dumps(order(event_id="v1")).encode())
    second = upload("incoming/orders.jsonl", json.dumps(order(event_id="v2")).encode())
    processor.process(first)
    processor.process(second)

    curated = store.names(CURATED_BUCKET, "curated/")
    assert len(curated) == 2
    assert [read_jsonl(store, n)[0]["event_id"] for n in curated] == ["v1", "v2"]


def test_only_quarantine_written_when_all_records_invalid(processor, store, upload):
    ref = upload("incoming/bad.jsonl", b"[1, 2, 3]\n42\n")
    result = processor.process(ref)
    assert result.valid == 0
    assert result.invalid == 2
    assert store.names(CURATED_BUCKET, "curated/") == []
    reasons = [q["reason"] for q in read_jsonl(store, output_paths(ref, processor._settings).quarantine)]
    assert reasons == ["not_an_object", "not_an_object"]


@pytest.mark.parametrize(
    ("payload", "reason"),
    [
        (b"\xff\xfe\x00garbage\x9c", "invalid_utf8"),
        (b'{"event_id": "x", ', "invalid_json"),  # truncated upload, no trailing newline
        (b'[{"event_id": "x"}]', "not_an_object"),  # JSON array instead of JSONL
    ],
)
def test_malformed_file_is_quarantined_not_retried(processor, store, upload, payload, reason):
    ref = upload("incoming/malformed.jsonl", payload)
    result = processor.process(ref)
    assert result.status == "processed"
    [record] = read_jsonl(store, output_paths(ref, processor._settings).quarantine)
    assert record["reason"] == reason


def test_oversized_line_is_quarantined_and_truncated(store, upload, settings):
    processor = Processor(store, replace(settings, max_line_bytes=100_000))
    ref = upload("incoming/huge.jsonl", b"x" * 200_000 + b"\n" + json.dumps(order()).encode())
    result = processor.process(ref)
    assert (result.valid, result.invalid) == (1, 1)
    [record] = read_jsonl(store, output_paths(ref, settings).quarantine)
    assert record["reason"] == "line_too_large"
    assert record["raw_truncated"] is True
    assert len(record["raw"]) == 64 * 1024


def test_empty_file_creates_no_outputs(processor, store, upload):
    result = processor.process(upload("incoming/empty.jsonl", b""))
    assert result.status == "processed"
    assert result.outputs == {}
    assert store.names(CURATED_BUCKET) == []


@pytest.mark.parametrize("name", ["landing/orders.jsonl", "incoming/orders.csv", "incoming/orders.jsonl.gz"])
def test_objects_outside_contract_are_skipped(processor, store, upload, name):
    result = processor.process(upload(name, json.dumps(order()).encode()))
    assert result.status == "skipped"
    assert store.names(CURATED_BUCKET) == []


def test_missing_source_generation_is_acknowledged(processor, store, upload):
    ref = upload("incoming/orders.jsonl", json.dumps(order()).encode())
    gone = ObjectRef(ref.bucket, ref.name, ref.generation + 999, ref.time_created)
    assert processor.process(gone).status == "source_missing"
    assert store.names(CURATED_BUCKET) == []


def test_transient_read_error_propagates_and_writes_nothing(processor, store, upload):
    ref = upload("incoming/orders.jsonl", json.dumps(order()).encode())
    store.fail_reads_with = TimeoutError("storage read timed out")
    with pytest.raises(TimeoutError):
        processor.process(ref)
    assert store.names(CURATED_BUCKET) == []


def test_large_file_is_streamed(processor, store, upload):
    n = 60_000  # ~13 MiB of input; output crosses the 1 MiB write buffer many times
    data = b"".join(json.dumps(order(event_id=f"e{i}", order_id=f"o{i}")).encode() + b"\n" for i in range(n))
    ref = upload("incoming/big.jsonl", data)

    result = processor.process(ref)

    assert (result.valid, result.invalid) == (n, 0)
    # Streaming proof: output chunks were written while input was still being read,
    # i.e. the processor never materialized the whole file or result in memory.
    first_write = store.trace.index("write")
    assert first_write < len(store.trace) - store.trace[::-1].index("read") - 1
    assert store.trace.count("write") > 5
    curated = store.get(CURATED_BUCKET, output_paths(ref, processor._settings).curated)
    assert curated.count(b"\n") == n
