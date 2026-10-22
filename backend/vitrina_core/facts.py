"""The facts of a pair a seller picks from ready options, never types: what the upper, the lining and the sole are
made of, the season and the country it was made in, and for some kinds of footwear one or two more (how high a boot
reaches, how warm it is, how high a heel is, how a sandal fastens). Stored by key, named in the app
(app/lib/labels.dart, in Kazakh, Russian and English); tests/test_core.py checks that the two agree.

Nothing typed means nothing to check for contacts or insults: picking a fact never sends the listing to moderation."""
from __future__ import annotations

# Fact -> its Kazakh name and the options a seller picks from, by key, each with its Kazakh name (the staff pages
# show these; the app has its own copy, translated).
NAMES: dict[str, tuple[str, dict[str, str]]] = {
    "upper": ("Үсті", {
        "leather": "Табиғи былғары", "faux_leather": "Жасанды былғары", "suede": "Күдері", "nubuck": "Нубук",
        "patent": "Лак былғары", "textile": "Тоқыма", "mesh": "Желдетілетін тор", "mixed": "Аралас материал",
        "rubber": "Резеңке", "eva": "Жеңіл көбік (EVA)", "felt": "Киіз"}),
    "lining": ("Іші", {
        "leather": "Табиғи былғары", "textile": "Тоқыма", "fur": "Табиғи мех", "faux_fur": "Жасанды мех",
        "wool": "Жүн", "felt": "Киіз", "none": "Астары жоқ"}),
    "sole": ("Табаны", {
        "rubber": "Резеңке", "eva": "Жеңіл көбік (EVA)", "pu": "Полиуретан", "tpr": "Термопластик (TPR)",
        "leather": "Былғары"}),
    "season": ("Маусым", {"summer": "Жаз", "demi": "Көктем-күз", "winter": "Қыс", "all": "Жыл бойы"}),
    "country": ("Елі", {
        "KZ": "Қазақстан", "TR": "Түркия", "CN": "Қытай", "RU": "Ресей", "KG": "Қырғызстан", "UZ": "Өзбекстан",
        "BY": "Беларусь", "VN": "Вьетнам", "IN": "Үндістан", "ID": "Индонезия", "IT": "Италия"}),
    "shaft": ("Қонышы", {
        "ankle": "Тобыққа дейін", "mid_calf": "Балтырдың ортасына дейін", "knee": "Тізеге дейін",
        "over_knee": "Тізеден жоғары"}),
    "warmth": ("Жылуы", {"none": "Жылусыз", "light": "Аздап жылы", "winter": "Қысқы"}),
    "heel": ("Өкше", {
        "flat": "Өкшесіз", "low": "Аласа (3 см-ге дейін)", "mid": "Орташа (3–7 см)", "high": "Биік (7 см-ден жоғары)"}),
    "fastening": ("Бекітпесі", {
        "buckle": "Тоға", "velcro": "Жабысқақ (липучка)", "elastic": "Резеңке бау", "laces": "Бау",
        "none": "Бекітпесіз"}),
}
FACTS: dict[str, tuple[str, ...]] = {key: tuple(options) for key, (_, options) in NAMES.items()}

# Every pair has these; the kind of footwear adds its own (a winter boot is warm by its kind: no warmth to ask).
COMMON = ("upper", "lining", "sole", "season", "country")
BY_CATEGORY: dict[str, tuple[str, ...]] = {
    "boots": ("shaft", "warmth"),
    "boots_winter": ("shaft",),
    "classic": ("heel",),
    "heels": ("heel",),
    "sandals": ("fastening",),
    "kids": ("warmth", "fastening"),
}


def fact_keys(category: str) -> tuple[str, ...]:
    """The facts asked for this kind of footwear, in the order a buyer reads them."""
    return COMMON + BY_CATEGORY.get(category, ())


def clean_facts(facts: dict[str, str] | None, category: str, *, stored: bool = False) -> dict[str, str] | None:
    """The facts to store: only picked ones this kind of footwear has, in order (a boot's height goes when the kind
    changes, and an older app's leftovers are let go). An unknown fact or option is refused, raising ValueError
    naming the fact, unless [stored]: facts saved before an option was withdrawn are kept where still known, never
    a reason to refuse the seller's other changes."""
    if not facts:
        return None
    out: dict[str, str] = {}
    for key, value in facts.items():
        if key not in FACTS or value not in FACTS[key]:
            if stored:
                continue
            raise ValueError(key)
        out[key] = value
    return {k: out[k] for k in fact_keys(category) if k in out} or None


def named_facts(facts: dict[str, str] | None, category: str | None) -> list[list[str]]:
    """The facts as the buyer read them, each [name, option] in Kazakh, for the staff pages."""
    return [[NAMES[k][0], NAMES[k][1][v]] for k, v in (clean_facts(facts, category or "", stored=True) or {}).items()]
