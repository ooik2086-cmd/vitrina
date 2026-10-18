"""The shoe colours a seller picks from, named in Kazakh as stored, with the Russian and English words sellers also
type. A colour typed in any of the three languages is stored under its Kazakh name, so one colour of a model never
shows as two swatches ("қара", "черный", "Black"). A colour not on the list is kept as typed.

The app's picker (app/lib/colors.dart) offers the same names; tests/test_core.py checks that the two agree."""
from __future__ import annotations

# Kazakh name -> other words for it (Russian, English, common spellings), all lower case.
COLORS: dict[str, tuple[str, ...]] = {
    "қара": ("черный", "чёрный", "black"),
    "ақ": ("белый", "white"),
    "сұр": ("серый", "grey", "gray"),
    "қоңыр": ("коричневый", "brown"),
    "құм": ("бежевый", "beige", "sand", "құм түсті"),
    "көк": ("синий", "blue"),
    "көгілдір": ("голубой", "light blue"),
    "қою көк": ("темно-синий", "тёмно-синий", "темно синий", "navy", "dark blue"),
    "жасыл": ("зеленый", "зелёный", "green"),
    "қызыл": ("красный", "red"),
    "қызғылт": ("розовый", "pink"),
    "сары": ("желтый", "жёлтый", "yellow"),
    "қызғылт сары": ("оранжевый", "orange"),
    "күлгін": ("фиолетовый", "purple", "violet"),
    "күміс": ("серебристый", "серебряный", "silver"),
    "алтын": ("золотой", "золотистый", "gold"),
    "аралас": ("разноцветный", "multicolor", "multicolour", "multi", "көп түсті"),
}

_BY_WORD = {word: name for name, words in COLORS.items() for word in (name, *words)}


def canonical_color(text: str) -> str:
    """The colour's Kazakh name when it is on the list in any language; otherwise the text with its spacing tidied."""
    tidy = " ".join(text.split())
    return _BY_WORD.get(tidy.casefold(), tidy)


def color_words(color: str) -> str:
    """The colour in every language it is known by, for search: "черный" and "black" both find "қара"."""
    return " ".join((color, *COLORS.get(color, ())))

