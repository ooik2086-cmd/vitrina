"""Public pages Google Play and the personal-data law ask for: /privacy (what is kept, why, who sees it) and
/delete-account (how to delete the account, what goes and what stays). Both say who runs the site and where to
write, from VITRINA_OPERATOR and VITRINA_SUPPORT_CONTACT; production does not start without them.

The texts are a draft until a lawyer has read them, and say so. They describe what the code does now: when that
changes (a payment partner, push notifications), the page changes with it.
"""
from __future__ import annotations

import html

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse

from .config import Settings
from .deps import get_settings
from .share import pick_lang, page

router = APIRouter()

DRAFT = {
    "kk": "Алдын ала нұсқа: заңгер тексергеннен кейін нақтыланады.",
    "ru": "Предварительная версия: будет уточнена после проверки юристом.",
    "en": "Draft: to be finalised after a lawyer's review.",
}
WHO = {
    "kk": ("Сайт пен қосымшаны жүргізетін", "Жеке деректер туралы жазыңыз"),
    "ru": ("Сайт и приложение ведёт", "По вопросам персональных данных пишите"),
    "en": ("The site and app are run by", "Write about your personal data to"),
}

PRIVACY = {
    "kk": ("Құпиялылық саясаты", """
<h2>Қандай деректер сақталады</h2>
<ul>
<li>Телефон нөміріңіз: кіру үшін. Кіру коды SMS арқылы Mobizon қызметі арқылы жіберіледі, оған тек нөмір мен код беріледі.</li>
<li>Профиль: атыңыз, қалаңыз, ал сатушыда дүкен атауы мен сипаттамасы.</li>
<li>Тауарлар: фотолар, бейне, сипаттама, баға мен өлшемдер. Олар барлығына көрінеді.</li>
<li>Тапсырыстар: алушының аты, телефоны, қаласы мен мекенжайы. Оларды сатушы жіберу үшін көреді.</li>
<li>Чат хабарлары мен фотолары, сұрақтар мен пікірлер.</li>
<li>Түпнұсқалықтың дәлелі (чек, қорап фотосы) және дау дәлелдері. Оларды тек сіз, екінші тарап пен қолдау қызметі көреді.</li>
<li>Сатушының ақша алатын деректері: шот иесінің аты, IBAN және ЖСН/БСН. Оларды тек қолдау қызметі көреді.</li>
<li>Таңдаулылар, сақталған іздеулер, жазылымдар мен хабарламалар.</li>
</ul>
<h2>Не үшін</h2>
<p>Кіру, сауда жасау, тауарды жеткізу, дауды шешу және алаяқтықтан қорғау үшін ғана. Деректеріңіз сатылмайды және жарнама үшін берілмейді.</p>
<h2>Қайда сақталады</h2>
<p>Қазақстан аумағындағы серверде. Әр түні резервтік көшірмесі жасалады.</p>
<h2>Аккаунтты өшіру</h2>
<p>Қосымшада: Профиль → Аккаунтты жою. Толығырақ: <a href="/delete-account?lang=kk">аккаунтты өшіру</a>.</p>
"""),
    "ru": ("Политика конфиденциальности", """
<h2>Какие данные хранятся</h2>
<ul>
<li>Номер телефона: для входа. Код входа отправляется по SMS через сервис Mobizon, ему передаются только номер и код.</li>
<li>Профиль: имя, город, а у продавца название и описание магазина.</li>
<li>Товары: фото, видео, описание, цена и размеры. Их видят все.</li>
<li>Заказы: имя, телефон, город и адрес получателя. Их видит продавец, чтобы отправить заказ.</li>
<li>Сообщения и фото в чате, вопросы и отзывы.</li>
<li>Подтверждение подлинности (чек, фото коробки) и доказательства в спорах. Их видят только вы, другая сторона и поддержка.</li>
<li>Реквизиты продавца для выплат: имя владельца счёта, IBAN и ИИН/БИН. Их видит только поддержка.</li>
<li>Избранное, сохранённые поиски, подписки и уведомления.</li>
</ul>
<h2>Зачем</h2>
<p>Только для входа, покупок и продаж, доставки, решения споров и защиты от мошенничества. Данные не продаются и не передаются для рекламы.</p>
<h2>Где хранятся</h2>
<p>На сервере на территории Казахстана. Каждую ночь делается резервная копия.</p>
<h2>Удаление аккаунта</h2>
<p>В приложении: Профиль → Удалить аккаунт. Подробнее: <a href="/delete-account?lang=ru">удаление аккаунта</a>.</p>
"""),
    "en": ("Privacy policy", """
<h2>What is kept</h2>
<ul>
<li>Your phone number: to sign in. The sign-in code is sent by SMS through Mobizon, which gets only the number and the code.</li>
<li>Your profile: name and city, and for sellers the shop's name and description.</li>
<li>Listings: photos, video, description, price and sizes. Everyone sees them.</li>
<li>Orders: the recipient's name, phone, city and address. The seller sees them to send the order.</li>
<li>Chat messages and photos, questions and reviews.</li>
<li>Proof of authenticity (receipt, box photo) and dispute evidence. Only you, the other side and support see them.</li>
<li>A seller's payout details: the account holder's name, IBAN and IIN/BIN. Only support sees them.</li>
<li>Favourites, saved searches, follows and notifications.</li>
</ul>
<h2>Why</h2>
<p>Only to sign in, buy and sell, deliver, settle disputes and protect against fraud. Your data is not sold or shared for advertising.</p>
<h2>Where</h2>
<p>On a server in Kazakhstan, backed up every night.</p>
<h2>Deleting your account</h2>
<p>In the app: Profile → Delete account. More: <a href="/delete-account?lang=en">deleting your account</a>.</p>
"""),
}

DELETE = {
    "kk": ("Аккаунтты өшіру", """
<h2>Қалай</h2>
<p>VITRINA қосымшасында: Профиль → Аккаунтты жою → Жою. Аккаунт бірден жойылады.</p>
<p>Қосымшаны аша алмасаңыз, төмендегі мекенжайға жазып, аккаунтқа тіркелген нөмірді көрсетіңіз. Қолдау қызметі сол нөмірге қоңырау шалып растайды, содан кейін аккаунтты жояды.</p>
<h2>Не өшіріледі</h2>
<p>Атыңыз, қалаңыз, дүкен атауы мен сипаттамасы, ақша алатын шот деректері, соңғы жеткізу мекенжайы, таңдаулылар, сақталған іздеулер, жазылымдар мен хабарламалар. Тауарларыңыз каталогтан алынады, ал телефон нөміріңіз аккаунттан ажыратылады.</p>
<h2>Не сақталады</h2>
<p>Тапсырыстар, төлемдер мен ақша шығару туралы жазбалар заң бойынша сақталады, оның ішінде тапсырыстағы алушы мен мекенжай және әр шығарылған соманың шот деректері. Жіберілген чат хабарлары әңгімелесушіде қалады.</p>
<p>Ашық тапсырыс болса не сатушыға төленетін ақша қалса, аккаунтты әзірге жою мүмкін емес: олар аяқталғаннан кейін жоюға болады.</p>
"""),
    "ru": ("Удаление аккаунта", """
<h2>Как</h2>
<p>В приложении VITRINA: Профиль → Удалить аккаунт → Удалить. Аккаунт удаляется сразу.</p>
<p>Если не можете открыть приложение, напишите по адресу ниже и укажите номер, на который зарегистрирован аккаунт. Поддержка позвонит на этот номер для подтверждения и затем удалит аккаунт.</p>
<h2>Что удаляется</h2>
<p>Имя, город, название и описание магазина, реквизиты для выплат, последний адрес доставки, избранное, сохранённые поиски, подписки и уведомления. Ваши товары снимаются с каталога, а номер телефона отвязывается от аккаунта.</p>
<h2>Что сохраняется</h2>
<p>Записи о заказах, платежах и выплатах хранятся по закону, включая получателя и адрес в заказе и реквизиты каждой выплаты. Отправленные сообщения в чате остаются у собеседника.</p>
<p>Пока есть незавершённый заказ или продавцу причитаются деньги, аккаунт удалить нельзя: это можно сделать после их завершения.</p>
"""),
    "en": ("Deleting your account", """
<h2>How</h2>
<p>In the VITRINA app: Profile → Delete account → Delete. The account is deleted at once.</p>
<p>If you cannot open the app, write to the address below with the number the account is registered to. Support calls that number to confirm, then deletes the account.</p>
<h2>What is deleted</h2>
<p>Your name, city, shop name and description, payout details, last delivery address, favourites, saved searches, follows and notifications. Your listings leave the catalog and your phone number is unlinked from the account.</p>
<h2>What is kept</h2>
<p>Records of orders, payments and payouts, as the law requires, including the recipient and address on each order and the bank details of each payout. Chat messages you sent stay with the other person.</p>
<p>While an order is still open or money is owed to a seller, the account cannot be deleted yet: it can be once they are settled.</p>
"""),
}

CSS = ("<style>.info h2{font-size:18px;margin:22px 0 6px}.info p,.info li{line-height:1.5}"
       ".info ul{padding-left:20px}.langs a{margin-right:12px}</style>")


def _render(texts: dict, path: str, request: Request, cfg: Settings) -> HTMLResponse:
    lang = pick_lang(request)
    title, body = texts[lang]
    who, write = WHO[lang]
    langs = " ".join(f'<a href="{path}?lang={code}">{name}</a>'
                     for code, name in (("kk", "Қазақша"), ("ru", "Русский"), ("en", "English")) if code != lang)
    operator = html.escape(cfg.operator or "VITRINA_OPERATOR")
    contact = html.escape(cfg.support_contact or "VITRINA_SUPPORT_CONTACT")
    return page(title, f"""<div class="info"><p class="langs muted">{langs}</p><h1>{html.escape(title)}</h1>
<p class="muted">{DRAFT[lang]}</p>{body}
<h2>{who}</h2><p>{operator}</p><p>{write}: <b>{contact}</b></p></div>""", lang=lang, meta=CSS)


@router.get("/privacy", response_class=HTMLResponse, include_in_schema=False)
def privacy(request: Request, cfg: Settings = Depends(get_settings)):
    return _render(PRIVACY, "/privacy", request, cfg)


@router.get("/delete-account", response_class=HTMLResponse, include_in_schema=False)
def delete_account(request: Request, cfg: Settings = Depends(get_settings)):
    return _render(DELETE, "/delete-account", request, cfg)
