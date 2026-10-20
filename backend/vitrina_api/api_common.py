"""What every API module shares: limits and constants the route modules agree on."""
from __future__ import annotations

import logging
import re
from datetime import timedelta, timezone

from vitrina_core.catalog import Condition
from vitrina_core.orders import OrderStatus as S


CATEGORIES = ("sneakers", "sport", "casual", "classic", "heels", "boots", "boots_winter", "sandals", "slippers", "work",
              "kids", "other")
# Whom a pair is made for; a unisex pair is shown to men and to women.
AUDIENCES = ("men", "women", "unisex", "kids")
PHONE_RE = re.compile(r"^\+7\d{10}$")
log = logging.getLogger("vitrina.api")

MIN_SPIN_FRAMES = 8  # fewer real frames than this do not read as a rotation
MAX_LISTING_MEDIA = 60  # the same limit a new listing has
MAX_LISTING_SIZES = 30
DEFECT_REQUIRED = {Condition.USED_GOOD.value, Condition.DEFECTIVE.value}



ALMATY = timezone(timedelta(hours=5))  # Kazakhstan has one time zone, UTC+5, since March 2024


IN_DELIVERY = (S.SHIPPED.value, S.IN_TRANSIT.value)
DECLINABLE = (S.PAID.value, S.SELLER_ACCEPTED.value, S.PREPARING.value)
