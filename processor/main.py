"""Cloud Functions (2nd gen) entry point."""

from __future__ import annotations

import functools

import functions_framework
from cloudevents.http import CloudEvent

from pipeline.config import Settings
from pipeline.handler import handle_event
from pipeline.logging_utils import configure_logging
from pipeline.processor import Processor

configure_logging()


@functools.cache
def _processor() -> Processor:
    # Created lazily (once per instance) so cold start and unit tests do not need credentials.
    from pipeline.gcs import GcsObjectStore

    return Processor(GcsObjectStore(), Settings.from_env())


@functions_framework.cloud_event
def process_raw_object(cloud_event: CloudEvent) -> None:
    handle_event(cloud_event["id"], cloud_event["type"], cloud_event.get_data(), _processor())
