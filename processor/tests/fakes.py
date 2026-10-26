"""In-memory ObjectStore with the same create-only/commit semantics as GCS."""

from __future__ import annotations

import io
from collections.abc import Iterator
from contextlib import contextmanager

from pipeline.storage import ObjectAlreadyExistsError, ObjectNotFoundError


class InMemoryObjectStore:
    def __init__(self) -> None:
        # (bucket, name) -> {generation: bytes}; the highest generation is live.
        self.objects: dict[tuple[str, str], dict[int, bytes]] = {}
        self._next_generation = 1_700_000_000_000_000
        self.trace: list[str] = []  # ordered "read"/"write" operations, used to prove streaming
        self.fail_reads_with: Exception | None = None
        self.fail_commit_for: set[str] = set()

    # --- helpers for tests -------------------------------------------------
    def put(self, bucket: str, name: str, data: bytes) -> int:
        self._next_generation += 1
        self.objects.setdefault((bucket, name), {})[self._next_generation] = data
        return self._next_generation

    def get(self, bucket: str, name: str) -> bytes:
        versions = self.objects[(bucket, name)]
        return versions[max(versions)]

    def names(self, bucket: str, prefix: str = "") -> list[str]:
        return sorted(n for (b, n) in self.objects if b == bucket and n.startswith(prefix))

    # --- ObjectStore protocol ---------------------------------------------
    def iter_lines(self, bucket: str, name: str, generation: int | None) -> Iterator[bytes]:
        if self.fail_reads_with is not None:
            raise self.fail_reads_with
        versions = self.objects.get((bucket, name))
        if not versions:
            raise ObjectNotFoundError(name)
        gen = generation if generation is not None else max(versions)
        if gen not in versions:
            raise ObjectNotFoundError(f"{name}#{gen}")
        for line in io.BytesIO(versions[gen]):
            self.trace.append("read")
            yield line

    @contextmanager
    def create_writer(self, bucket: str, name: str, content_type: str) -> Iterator[_Writer]:
        writer = _Writer(self)
        yield writer  # an exception escaping here aborts: nothing is stored
        if name in self.fail_commit_for:
            raise ConnectionError(f"simulated transient failure committing {name}")
        if (bucket, name) in self.objects:
            raise ObjectAlreadyExistsError(name)
        self.put(bucket, name, writer.buffer.getvalue())


class _Writer:
    def __init__(self, store: InMemoryObjectStore) -> None:
        self._store = store
        self.buffer = io.BytesIO()

    def write(self, data: bytes) -> None:
        self._store.trace.append("write")
        self.buffer.write(data)
