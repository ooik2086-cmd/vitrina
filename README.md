# VITRINA AI

Қазақстанға арналған аяқкиім маркетплейсі: шынайы фотолардан жасалған 360° витрина және қорғалған мәміле. Android бірінші.

Күйі (17.10.2026): сервер, Flutter қосымшасы, қолдау қызметінің панелі, Docker және CI.

## Не бар

| Папка | Не | Деңгейі |
| --- | --- | --- |
| `backend/vitrina_core/` | Тапсырыс күйлерінің машинасы (14 күй), ақша тиынмен және ledger, комиссия, webhook қолтаңбасы, баға сегменттері, бренд синонимдері | Жұмыс істейді, 27 тест |
| `backend/vitrina_api/` | HTTP API (FastAPI, SQLAlchemy, 18 кесте): телефонмен кіру, сатушы режимі, фото жүктеу (тексеру, метадерек тазалау), тауар жариялау (360° үшін кемінде 8 кадр), іздеу (кирилл/латын), таңдаулылар, тапсырыс және тарихы, төлем мен жеткізу webhook-тары, дау, чат (байланыс деректерін белгілеу), пікір мен рейтинг, хабарламалар, аудит | Жұмыс істейді, 29 API тесті SQLite және PostgreSQL-де; SMS пен төлем әлі sandbox |
| `backend/vitrina_api/admin/` | Қолдау панелі `/admin`: шолу, дауларды шешу (толық/ішінара қайтару, себебі міндетті), тауарды жасыру, аудит журналы | Жұмыс істейді, тек support/admin рөлі |
| `backend/migrations/` | Alembic миграциялары | Модельмен сәйкестігі тестпен тексеріледі |
| `app/` | Flutter қосымшасы: каталог, іздеу, өлшем см бойынша, 360° тауар беті, таңдаулылар, чат, тапсырыс беті уақыт сызығымен, пікір қалдыру, хабарламалар, сатушының тауарлары, камерамен 360° түсіру (алдыңғы кадр көлеңкесімен) | Жұмыс істейді, 9 тест |
| `backend/demo/frames/` | 3 түсті аяқкиімнің 36 кадрлық 360° тізбегі | Shopify MaterialsVariantsShoe, CC BY 4.0, қараңыз `backend/demo/ATTRIBUTION.md` |
| `prototype/vitrina-360.html` | Алғашқы HTML прототип | Тарихи |

Әлі жоқ: нақты SMS, төлем және жеткізу провайдерлері (серіктес керек), суретпен іздеу, фон алу, push-хабарламалар, Қазақстан заңы бойынша тексеру.

## Тесттер

```
cd backend
python3 -m pip install -r requirements.txt
python3 -m unittest
```

Күтілетін нәтиже: `Ran 57 tests ... OK`. PostgreSQL-де тексеру: `VITRINA_TEST_DATABASE_URL=postgresql+psycopg://... python3 -m unittest tests.test_api`.

Қосымша: `cd app && flutter analyze && flutter test`.

CI (GitHub Actions) әр push-та: backend, PostgreSQL-мен backend, Flutter (analyze, test, debug APK — артефакт ретінде жүктеледі), Docker compose.

## Іске қосу

Docker арқылы (PostgreSQL + API):

```
docker compose up --build
```

Docker-сіз:

```
cd backend
python3 -m uvicorn vitrina_api.app:create_app --factory --reload
python3 scripts/seed_demo.py        # 4 демо тауар
```

- API құжаты: http://127.0.0.1:8000/docs
- Қолдау панелі: http://127.0.0.1:8000/admin/ (пайдаланушыға дерекқорда `role='admin'` немесе `'support'` берілуі керек)
- Әзірлеуде SMS орнына код жауапта `dev_code` болып келеді. Production-да `VITRINA_DEBUG_OTP=0`, барлық `VITRINA_*_SECRET` мәндері, `VITRINA_AUTO_CREATE_SCHEMA=0` және `alembic upgrade head` міндетті.
- Flutter web-тен сұрау үшін: `VITRINA_CORS_ORIGINS=http://localhost:5000`.

## Келесі қадам

1. Лицензиясы бар төлем серіктесі және SMS провайдері; онсыз «қорғалған мәміле» іске қосылмайды.
2. Фото сақтау S3/CDN-ге (қазір диск).
3. Фон алу және суретпен іздеу.
4. Push-хабарламалар (FCM).
5. Заңгерлік тексеру: оферта, жеке деректер, қайтару ережелері.
