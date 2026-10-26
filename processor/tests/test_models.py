from __future__ import annotations

from decimal import Decimal

import pytest
from pydantic import ValidationError

from pipeline.models import OrderEvent
from tests.conftest import order

SOURCE = {"bucket": "b", "object": "o", "generation": 1, "line": 1}


def test_valid_event_is_normalized():
    curated = OrderEvent.model_validate(order()).to_curated(source=SOURCE)
    assert curated["currency"] == "USD"
    # 23:15 at UTC+2 is 21:15Z on the same day.
    assert curated["occurred_at"] == "2026-10-25T21:15:00Z"
    assert curated["event_date"] == "2026-10-25"
    assert curated["total_amount"] == "19.98"
    assert curated["item_count"] == 2
    assert curated["items"] == [{"sku": "SKU-1", "quantity": 2, "unit_price": "9.99"}]
    assert curated["_source"] == SOURCE


def test_timezone_shift_can_change_event_date():
    curated = OrderEvent.model_validate(order(occurred_at="2026-10-25T23:30:00-05:00")).to_curated(source=SOURCE)
    assert curated["event_date"] == "2026-10-26"


def test_total_is_optional_and_computed():
    event = OrderEvent.model_validate(
        order(total_amount=None, items=[{"sku": "A", "quantity": 3, "unit_price": "0.335"}])
    )
    assert event.computed_total == Decimal("1.005")
    assert event.to_curated(source=SOURCE)["total_amount"] == "1.01"  # half-up rounding


@pytest.mark.parametrize(
    ("overrides", "expected_loc"),
    [
        ({"event_type": "order_shipped"}, "event_type"),
        ({"occurred_at": "2026-10-25T21:15:00"}, "occurred_at"),  # naive timestamp
        ({"occurred_at": "2999-01-01T00:00:00Z"}, "occurred_at"),  # far future
        ({"currency": "US"}, "currency"),
        ({"items": []}, "items"),
        ({"items": [{"sku": "A", "quantity": 0, "unit_price": "1"}]}, "items.0.quantity"),
        ({"items": [{"sku": "A", "quantity": 1, "unit_price": "-1"}]}, "items.0.unit_price"),
        ({"order_id": "   "}, "order_id"),
        ({"unexpected": True}, "unexpected"),
        ({"total_amount": "20.00"}, ""),  # model-level check: total mismatch
    ],
)
def test_invalid_events_are_rejected(overrides, expected_loc):
    with pytest.raises(ValidationError) as exc_info:
        OrderEvent.model_validate(order(**overrides))
    locs = [".".join(str(p) for p in e["loc"]) for e in exc_info.value.errors()]
    assert expected_loc in locs


def test_missing_required_field():
    payload = order()
    del payload["customer_id"]
    with pytest.raises(ValidationError, match="customer_id"):
        OrderEvent.model_validate(payload)
