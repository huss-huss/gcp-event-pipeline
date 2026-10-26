"""Pydantic schema for raw order events and their normalized (curated) form."""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import ROUND_HALF_UP, Decimal
from typing import Annotated, Any, Literal

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
    model_validator,
)

NonEmptyStr = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=128)]
CENT = Decimal("0.01")


class LineItem(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    sku: NonEmptyStr
    quantity: int = Field(gt=0, le=10_000)
    unit_price: Decimal = Field(ge=0, max_digits=12, decimal_places=4)


class OrderEvent(BaseModel):
    """A single order lifecycle event as produced by upstream systems (one JSON object per line)."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    event_id: NonEmptyStr
    event_type: Literal["order_created", "order_updated", "order_cancelled"]
    order_id: NonEmptyStr
    customer_id: NonEmptyStr
    occurred_at: AwareDatetime
    currency: Annotated[str, StringConstraints(strip_whitespace=True, to_upper=True, pattern=r"^[A-Za-z]{3}$")]
    items: list[LineItem] = Field(min_length=1, max_length=1_000)
    total_amount: Decimal | None = Field(default=None, ge=0, max_digits=14, decimal_places=4)

    @field_validator("occurred_at")
    @classmethod
    def _not_in_far_future(cls, value: datetime) -> datetime:
        # Clock skew tolerance is generous; anything beyond a day is a producer bug.
        if (value - datetime.now(UTC)).total_seconds() > 86_400:
            raise ValueError("occurred_at is more than 24h in the future")
        return value

    @model_validator(mode="after")
    def _total_matches_items(self) -> OrderEvent:
        if self.total_amount is not None and _money(self.total_amount) != _money(self.computed_total):
            raise ValueError(f"total_amount {self.total_amount} does not match sum of items {self.computed_total}")
        return self

    @property
    def computed_total(self) -> Decimal:
        return sum((item.unit_price * item.quantity for item in self.items), Decimal("0"))

    def to_curated(self, *, source: dict[str, Any]) -> dict[str, Any]:
        """Return the normalized record written to the curated zone.

        Output is deterministic for a given input so that a redelivered event
        produces byte-identical output.
        """
        occurred_utc = self.occurred_at.astimezone(UTC)
        return {
            "event_id": self.event_id,
            "event_type": self.event_type,
            "order_id": self.order_id,
            "customer_id": self.customer_id,
            "occurred_at": occurred_utc.isoformat().replace("+00:00", "Z"),
            "event_date": occurred_utc.date().isoformat(),
            "currency": self.currency,
            "item_count": sum(item.quantity for item in self.items),
            "total_amount": str(_money(self.computed_total)),
            "items": [
                {
                    "sku": item.sku,
                    "quantity": item.quantity,
                    "unit_price": str(_money(item.unit_price)),
                }
                for item in self.items
            ],
            "_source": source,
        }


def _money(value: Decimal) -> Decimal:
    return value.quantize(CENT, rounding=ROUND_HALF_UP)
