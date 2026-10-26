"""Storage abstraction used by the processor.

The processor only needs two capabilities:

* stream the lines of a specific object *generation* (so a later overwrite of
  the same name can never be processed under an old event), and
* create a new object **only if it does not already exist**. Writers commit on
  successful exit of the context manager and abort (nothing visible) when an
  exception escapes, so partially processed files never become visible.

``GcsObjectStore`` (``pipeline.gcs``) implements this against Cloud Storage;
tests use an in-memory fake with the same semantics.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import AbstractContextManager
from typing import Protocol


class ObjectNotFoundError(Exception):
    """The requested object (or generation) does not exist."""


class ObjectAlreadyExistsError(Exception):
    """A create-only write found an existing object at the target name."""


class ObjectWriter(Protocol):
    def write(self, data: bytes) -> None: ...


class ObjectStore(Protocol):
    def iter_lines(self, bucket: str, name: str, generation: int | None) -> Iterator[bytes]:
        """Yield raw lines (including any trailing newline) without loading the object into memory."""
        ...

    def create_writer(self, bucket: str, name: str, content_type: str) -> AbstractContextManager[ObjectWriter]:
        """Open a create-only writer.

        Raises ``ObjectAlreadyExistsError`` (on open or on commit) when the target exists.
        """
        ...
