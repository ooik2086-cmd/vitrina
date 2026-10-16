"""Catalog helpers: price segments from data, condition/authenticity kept separate,
and query normalization for Kazakh/Russian/English, Cyrillic/Latin brand names."""
from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum


class Condition(str, Enum):
    NEW_WITH_BOX = "new_with_box"
    NEW_NO_BOX = "new_no_box"
    UNWORN_STORED = "unworn_stored"
    USED_EXCELLENT = "used_excellent"
    USED_GOOD = "used_good"
    DEFECTIVE = "defective"


class Authenticity(str, Enum):
    UNVERIFIED = "unverified"
    SELLER_EVIDENCE = "seller_evidence"
    DOCUMENTED = "documented"
    VERIFIED = "verified"


class Segment(str, Enum):
    ECONOMY = "economy"
    MID = "mid"
    PREMIUM = "premium"
    LUXURY = "luxury"


MIN_SAMPLE = 200


@dataclass(frozen=True)
class SegmentBounds:
    category: str
    mid_from: int
    premium_from: int
    luxury_from: int

    def segment_for(self, price_tiyn: int) -> Segment:
        if price_tiyn >= self.luxury_from:
            return Segment.LUXURY
        if price_tiyn >= self.premium_from:
            return Segment.PREMIUM
        if price_tiyn >= self.mid_from:
            return Segment.MID
        return Segment.ECONOMY


def _quantile(sorted_vals: list[int], q: float) -> int:
    idx = round(q * (len(sorted_vals) - 1))
    return sorted_vals[idx]


def compute_bounds(category: str, prices_tiyn: list[int]) -> SegmentBounds | None:
    """Bounds at the 25th/60th/90th percentile of real catalog prices.
    Returns None when there is not enough data: then only the price is shown."""
    if len(prices_tiyn) < MIN_SAMPLE:
        return None
    vals = sorted(prices_tiyn)
    return SegmentBounds(category, _quantile(vals, 0.25), _quantile(vals, 0.60), _quantile(vals, 0.90))


# Minimal starter table; the real one lives in the database and is edited by admins.
BRAND_SYNONYMS = {
    "найк": "nike", "найки": "nike",
    "адидас": "adidas",
    "нью баланс": "new balance", "ньюбаланс": "new balance", "nb": "new balance",
    "пума": "puma",
    "конверс": "converse",
    "ванс": "vans",
    "рибок": "reebok",
    "асикс": "asics",
    "саломон": "salomon",
}

_CYR_TO_LAT = {
    "а": "a", "ә": "a", "б": "b", "в": "v", "г": "g", "ғ": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "i", "к": "k", "қ": "q", "л": "l", "м": "m", "н": "n",
    "ң": "n", "о": "o", "ө": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ұ": "u",
    "ү": "u", "ф": "f", "х": "h", "һ": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh", "ъ": "",
    "ы": "y", "і": "i", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def transliterate(text: str) -> str:
    return "".join(_CYR_TO_LAT.get(ch, ch) for ch in text)


_ALIAS_RE = re.compile(
    r"(?<!\w)(" + "|".join(re.escape(a) for a in sorted(BRAND_SYNONYMS, key=len, reverse=True)) + r")(?!\w)"
)


def normalize_query(query: str) -> str:
    """Lower-case, collapse spaces, map brand aliases (whole words only), then
    transliterate the rest so 'кроссовки найк' and 'krossovki nike' match."""
    q = " ".join(query.lower().split())
    q = _ALIAS_RE.sub(lambda m: BRAND_SYNONYMS[m.group(1)], q)
    return transliterate(q)
