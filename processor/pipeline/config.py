"""Runtime configuration, read from environment variables set by Terraform."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    curated_bucket: str
    raw_prefix: str = "incoming/"
    curated_prefix: str = "curated/orders"
    quarantine_prefix: str = "quarantine/orders"
    max_line_bytes: int = 1024 * 1024

    @classmethod
    def from_env(cls) -> Settings:
        try:
            curated_bucket = os.environ["CURATED_BUCKET"]
        except KeyError as exc:
            raise RuntimeError("CURATED_BUCKET environment variable is required") from exc
        return cls(
            curated_bucket=curated_bucket,
            raw_prefix=os.environ.get("RAW_PREFIX", cls.raw_prefix),
            curated_prefix=os.environ.get("CURATED_PREFIX", cls.curated_prefix).strip("/"),
            quarantine_prefix=os.environ.get("QUARANTINE_PREFIX", cls.quarantine_prefix).strip("/"),
            max_line_bytes=int(os.environ.get("MAX_LINE_BYTES", cls.max_line_bytes)),
        )
