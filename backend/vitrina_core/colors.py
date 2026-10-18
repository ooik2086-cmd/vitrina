"""The shoe colours a seller picks from, named in Kazakh as stored, with the Russian and English words sellers and
buyers also type. A colour typed in any of these words is stored under its Kazakh name, so one colour of a model never
shows as two swatches ("қара", "черный", "Black"). A colour not on the list is kept as typed.

Search works the other way round: the words of a query are turned into the Kazakh name before matching, so the stored
search text holds only the colour itself and never needs rebuilding when the list grows.

The app's picker (app/lib/colors.dart) offers the same names; tests/test_core.py checks that the two agree."""
from __future__ import annotations

import re
import unicodedata

# Kazakh name -> other words for it: Kazakh typed without Kazakh letters, Russian (base form; the other forms are
# made below), English. All lower case.
COLORS: dict[str, tuple[str, ...]] = {
    "қара": ("кара", "черный", "чёрный", "black"),
    "ақ": ("ак", "белый", "white"),
    "сұр": ("сур", "серый", "grey", "gray"),
    "қоңыр": ("коныр", "коричневый", "brown"),
    "құм түсті": ("құм", "кум", "бежевый", "беж", "beige", "sand"),
    "сүт түсті": ("сут тусти", "молочный", "кремовый", "cream", "off-white", "ivory"),
    "көк": ("кок", "синий", "blue"),
    "көгілдір": ("когилдир", "голубой", "light blue"),
    "қою көк": ("кою кок", "темно-синий", "тёмно-синий", "navy", "dark blue"),
    "жасыл": ("зеленый", "зелёный", "green"),
    "хаки": ("оливковый", "khaki", "olive"),
    "қызыл": ("кызыл", "красный", "red"),
    "бордо": ("бордовый", "burgundy", "maroon"),
    "қызғылт": ("кызгылт", "розовый", "pink"),
    "сары": ("желтый", "жёлтый", "yellow"),
    "қызғылт сары": ("кызгылт сары", "оранжевый", "orange"),
    "күлгін": ("кулгин", "фиолетовый", "purple", "violet"),
    "күміс": ("кумис", "серебристый", "серебряный", "silver"),
    "алтын": ("золотой", "золотистый", "gold"),
    "қара-ақ": ("кара-ак", "ақ-қара", "черно-белый", "чёрно-белый", "бело-черный", "бело-чёрный", "black-white",
                "black/white", "white-black", "white/black"),
    "түрлі түсті": ("аралас", "көп түсті", "разноцветный", "multicolor", "multicolour", "multi"),
}

_HARD = ("ый", "ой", "ая", "ое", "ые", "ого", "ому", "ую", "ым", "ых", "ыми")
_SOFT = ("ий", "яя", "ее", "ие", "его", "ему", "юю", "им", "их", "ими")


def _forms(word: str) -> tuple[str, ...]:
    """A Russian colour adjective in every gender, number and case a buyer writes: "черные", "белая"."""
    if re.fullmatch(r"[а-яё-]+(ый|ой)", word):
        return tuple(word[:-2] + e for e in _HARD)
    if re.fullmatch(r"[а-яё-]+ий", word):
        return tuple(word[:-2] + e for e in _SOFT)
    return (word,)


def _visible(text: str) -> str:
    """Without invisible or direction-changing characters, which could make a colour look blank or like another."""
    return "".join(ch for ch in text if unicodedata.category(ch) != "Cf")


def _fold(text: str) -> str:
    return " ".join(_visible(text).split()).casefold().replace("ё", "е")


WORDS: dict[str, str] = {_fold(w): name for name, others in COLORS.items()
                         for word in (name, *others) for w in _forms(word)}

_WORD_RE = re.compile(r"(?<![\w/-])(" + "|".join(re.escape(w) for w in sorted(WORDS, key=len, reverse=True))
                      + r")(?![\w/-])")


def canonical_color(text: str) -> str:
    """The colour's Kazakh name when it is on the list in any of its words; otherwise the text, tidied."""
    tidy = " ".join(_visible(text).split())
    return WORDS.get(_fold(tidy), tidy)


def color_query(query: str) -> str:
    """A search query with each colour word turned into the stored Kazakh name: "черные кроссовки" finds "қара"."""
    return _WORD_RE.sub(lambda m: WORDS[m.group(1)], _fold(query))
