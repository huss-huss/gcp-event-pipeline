"""Cloud Storage implementation of :class:`pipeline.storage.ObjectStore`."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

from google.api_core import exceptions as gexc
from google.cloud import storage

from pipeline.storage import ObjectAlreadyExistsError, ObjectNotFoundError, ObjectWriter

# 8 MiB chunks: large enough to keep request count low, small enough for a
# 512 MiB function instance to hold a reader and two writers comfortably.
CHUNK_SIZE = 8 * 1024 * 1024


class GcsObjectStore:
    def __init__(self, client: storage.Client | None = None) -> None:
        self._client = client or storage.Client()

    def iter_lines(self, bucket: str, name: str, generation: int | None) -> Iterator[bytes]:
        blob = self._client.bucket(bucket).blob(name, generation=generation)
        try:
            # BlobReader downloads in ranged chunks; iterating yields lines lazily.
            with blob.open("rb", chunk_size=CHUNK_SIZE) as reader:
                yield from reader
        except gexc.NotFound as exc:
            raise ObjectNotFoundError(f"gs://{bucket}/{name}#{generation}") from exc

    @contextmanager
    def create_writer(self, bucket: str, name: str, content_type: str) -> Iterator[ObjectWriter]:
        blob = self._client.bucket(bucket).blob(name, chunk_size=CHUNK_SIZE)
        # if_generation_match=0 makes the upload succeed only if no live object
        # exists at this name. This needs storage.objects.create only, so the
        # runtime identity never requires read/overwrite/delete on curated data.
        writer = blob.open(
            "wb",
            content_type=content_type,
            if_generation_match=0,
            ignore_flush=True,
        )
        try:
            yield _BytesWriter(writer)
        except BaseException:
            writer.terminate()  # cancel the resumable upload; nothing becomes visible
            raise
        try:
            writer.close()
        except gexc.PreconditionFailed as exc:
            raise ObjectAlreadyExistsError(f"gs://{bucket}/{name}") from exc


class _BytesWriter:
    def __init__(self, inner) -> None:
        self._inner = inner

    def write(self, data: bytes) -> None:
        try:
            self._inner.write(data)
        except gexc.PreconditionFailed as exc:
            # Large outputs initiate the resumable session on the first full chunk,
            # where GCS evaluates the precondition early.
            raise ObjectAlreadyExistsError(str(exc)) from exc
