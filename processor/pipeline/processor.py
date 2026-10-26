"""Core raw -> curated processing logic (pure Python, storage injected)."""

from __future__ import annotations

import contextlib
import json
import logging
import re
import time
from dataclasses import dataclass, field
from typing import Any

from pydantic import ValidationError

from pipeline.config import Settings
from pipeline.events import ObjectRef
from pipeline.models import OrderEvent
from pipeline.storage import ObjectAlreadyExistsError, ObjectNotFoundError, ObjectStore

logger = logging.getLogger("pipeline.processor")

SUPPORTED_SUFFIXES = (".jsonl", ".ndjson")
CONTENT_TYPE = "application/x-ndjson"
WRITE_BUFFER_BYTES = 1024 * 1024
MAX_RAW_IN_QUARANTINE = 64 * 1024
_UNSAFE = re.compile(r"[^A-Za-z0-9._=-]+")


@dataclass(frozen=True)
class OutputPaths:
    curated: str
    quarantine: str


@dataclass
class ProcessResult:
    status: str  # processed | skipped | source_missing
    reason: str = ""
    lines: int = 0
    valid: int = 0
    invalid: int = 0
    outputs: dict[str, str] = field(default_factory=dict)  # object name -> written|already_exists


def output_paths(ref: ObjectRef, settings: Settings) -> OutputPaths:
    """Deterministic output names: same (object, generation) -> same outputs.

    The partition is the *ingestion* date (object creation time, UTC), which
    is stable across redeliveries, unlike wall-clock processing time.
    """
    relative = ref.name[len(settings.raw_prefix) :] if ref.name.startswith(settings.raw_prefix) else ref.name
    for suffix in SUPPORTED_SUFFIXES:
        if relative.endswith(suffix):
            relative = relative[: -len(suffix)]
            break
    stem = _UNSAFE.sub("_", relative.replace("/", "__")).strip("_") or "object"
    filename = f"{stem}-g{ref.generation}.jsonl"
    partition = f"ingest_date={ref.time_created.date().isoformat()}"
    return OutputPaths(
        curated=f"{settings.curated_prefix}/{partition}/{filename}",
        quarantine=f"{settings.quarantine_prefix}/{partition}/{filename}",
    )


class Processor:
    def __init__(self, store: ObjectStore, settings: Settings) -> None:
        self._store = store
        self._settings = settings

    def process(self, ref: ObjectRef) -> ProcessResult:
        log_ctx = {"source": ref.uri}
        if not ref.name.startswith(self._settings.raw_prefix):
            return self._skip(ref, "outside raw prefix")
        if not ref.name.endswith(SUPPORTED_SUFFIXES):
            return self._skip(ref, "unsupported file extension")

        paths = output_paths(ref, self._settings)
        curated = _LazyOutput(self._store, self._settings.curated_bucket, paths.curated)
        quarantine = _LazyOutput(self._store, self._settings.curated_bucket, paths.quarantine)
        result = ProcessResult(status="processed")
        started = time.monotonic()

        try:
            for line_no, raw in enumerate(self._store.iter_lines(ref.bucket, ref.name, ref.generation), 1):
                result.lines = line_no
                record, error = self._parse_line(raw, ref, line_no)
                if record is None and error is None:
                    continue  # blank line
                if error is not None:
                    result.invalid += 1
                    quarantine.write_record(error)
                else:
                    result.valid += 1
                    curated.write_record(record)
        except ObjectNotFoundError:
            curated.abort()
            quarantine.abort()
            logger.warning("source object not found; acknowledging", extra={"event": "source_missing", **log_ctx})
            return ProcessResult(status="source_missing", reason="object or generation no longer exists")
        except BaseException:
            curated.abort()
            quarantine.abort()
            raise

        for output in (curated, quarantine):
            state = output.commit()
            if state != "empty":
                result.outputs[output.name] = state

        logger.info(
            "processed object",
            extra={
                "event": "file_processed",
                **log_ctx,
                "lines": result.lines,
                "valid_records": result.valid,
                "invalid_records": result.invalid,
                "outputs": result.outputs,
                "duration_ms": round((time.monotonic() - started) * 1000, 1),
            },
        )
        return result

    def _parse_line(
        self, raw: bytes, ref: ObjectRef, line_no: int
    ) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        stripped = raw.rstrip(b"\r\n")
        if not stripped.strip():
            return None, None
        if len(stripped) > self._settings.max_line_bytes:
            return None, _quarantine(line_no, "line_too_large", stripped, [f"{len(stripped)} bytes"])
        try:
            text = stripped.decode("utf-8")
        except UnicodeDecodeError as exc:
            return None, _quarantine(line_no, "invalid_utf8", stripped, [str(exc)])
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            return None, _quarantine(line_no, "invalid_json", stripped, [str(exc)])
        if not isinstance(payload, dict):
            return None, _quarantine(line_no, "not_an_object", stripped, [type(payload).__name__])
        try:
            event = OrderEvent.model_validate(payload)
        except ValidationError as exc:
            errors = [
                {"loc": ".".join(str(p) for p in err["loc"]), "type": err["type"], "msg": err["msg"]}
                for err in exc.errors(include_url=False, include_input=False)
            ]
            return None, _quarantine(line_no, "schema_validation", stripped, errors)
        source = {"bucket": ref.bucket, "object": ref.name, "generation": ref.generation, "line": line_no}
        return event.to_curated(source=source), None

    def _skip(self, ref: ObjectRef, reason: str) -> ProcessResult:
        logger.info("skipping object", extra={"event": "file_skipped", "source": ref.uri, "reason": reason})
        return ProcessResult(status="skipped", reason=reason)


def _quarantine(line_no: int, reason: str, raw: bytes, errors: list[Any]) -> dict[str, Any]:
    truncated = len(raw) > MAX_RAW_IN_QUARANTINE
    return {
        "line": line_no,
        "reason": reason,
        "errors": errors,
        "raw": raw[:MAX_RAW_IN_QUARANTINE].decode("utf-8", errors="replace"),
        "raw_truncated": truncated,
    }


class _LazyOutput:
    """Create-only output opened on first record, buffered, committed once.

    States: empty (nothing written, nothing created), open, written,
    already_exists (an earlier delivery already committed this output).
    """

    def __init__(self, store: ObjectStore, bucket: str, name: str) -> None:
        self._store = store
        self._bucket = bucket
        self.name = name
        self._cm = None
        self._writer = None
        self._buffer = bytearray()
        self.state = "empty"

    def write_record(self, record: dict[str, Any]) -> None:
        if self.state == "already_exists":
            return
        self._buffer += json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        self._buffer += b"\n"
        if len(self._buffer) >= WRITE_BUFFER_BYTES:
            self._flush()

    def _flush(self) -> None:
        if not self._buffer or self.state == "already_exists":
            return
        try:
            if self._cm is None:
                self._cm = self._store.create_writer(self._bucket, self.name, CONTENT_TYPE)
                self._writer = self._cm.__enter__()
                self.state = "open"
            self._writer.write(bytes(self._buffer))
        except ObjectAlreadyExistsError:
            self._mark_exists()
        self._buffer.clear()

    def commit(self) -> str:
        self._flush()
        if self.state == "open":
            try:
                self._cm.__exit__(None, None, None)
                self.state = "written"
            except ObjectAlreadyExistsError:
                self.state = "already_exists"
            self._cm = self._writer = None
        if self.state == "already_exists":
            logger.info(
                "output already exists; duplicate delivery",
                extra={"event": "duplicate_output", "output": self.name},
            )
        return self.state

    def abort(self) -> None:
        self._buffer.clear()
        if self._cm is not None:
            err = RuntimeError("processing aborted")
            with contextlib.suppress(RuntimeError):
                self._cm.__exit__(RuntimeError, err, None)
            self._cm = self._writer = None
        if self.state == "open":
            self.state = "empty"

    def _mark_exists(self) -> None:
        self.abort()
        self.state = "already_exists"
