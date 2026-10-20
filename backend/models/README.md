# Модельдер

Екі модель де міндетті емес: олар болмаса сервер жұмыс істей береді, тек тиісті мүмкіндік өшіп тұрады.

## Фонды алып тастау

Сервер тауар фотосының фонын мөлдір етеді, сонда 360° көрініс сатушы таңдаған витрина стилінде көрінеді.
Модель тек мөлдірлікті өзгертеді: аяқкиімнің түсі мен пішіні түпнұсқа фотодағыдай қалады (`tests/test_cutout.py`).
Сатып алушы «Фото» қойындысында әрқашан өңделмеген түпнұсқаны көреді.

| Модель | Лицензия | Дереккөз | SHA-256 |
| --- | --- | --- | --- |
| `isnet-general-use.onnx` (әдепкі) | Apache-2.0, [IS-Net / DIS](https://github.com/xuebinqin/DIS) | https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx | `60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a` |
| `u2net.onnx` | Apache-2.0, [U²-Net](https://github.com/xuebinqin/U-2-Net) | https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net.onnx | `8d10d2f3bb75ae3b6d527c77944fc5e7dcd94b29809d47a739a7a728a912b491` |

Модель (~170 МБ) репода сақталмайды. Docker образы оны жинау кезінде жүктеп, хешін тексереді.
Docker-сіз:

```
curl -L -o models/isnet-general-use.onnx https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx
export VITRINA_CUTOUT_MODEL=models/isnet-general-use.onnx
VITRINA_CUTOUT_MODEL=models/isnet-general-use.onnx python3 -m unittest tests.test_cutout   # нақты модельмен тексеру
```

Модель болмаса, сервер әдеттегідей жұмыс істейді, тек фотолар түпнұсқа күйінде көрсетіледі.
Нақты серверде жаңа тауарлардың фотосын `python3 -m vitrina_api.photo_worker` өңдейді (`VITRINA_PHOTO_WORK=worker`,
негізгі README-ді қараңыз). Ол жетіспейтінін өзі тауып, құлаған жұмысты кейін қайталайды.
Бар тауарларды бір рет өңдеу (фон және іздеу векторы): `python3 scripts/cutout_backfill.py`. Оны `alembic upgrade head`-тен
кейін іске қосыңыз. Фото процесі жоқ болса (`VITRINA_PHOTO_WORK=inline`), оны кестемен (мысалы, түнде бір рет) немесе
журналда «failed for listing» қатесі шыққанда қайта іске қосыңыз: API ішіндегі фондық тапсырма құласа, қайталап көрмейді.
Қайта іске қосу қауіпсіз: ол тек жетіспейтінін жасайды. Модель аяқкиім таппаған фото белгіленеді және сол модельмен
қайта кесілмейді (модельді ауыстырсаңыз, қайта байқап көреді). 360° айналымның бір бөлігінде осындай кадр болса, сол бөлік
түсірілген күйінде көрсетіледі. Соңғы жол нәтижені айтады, ал шығу коды: 0 бәрі дайын, 1 кейбір тауарлар өңделмеді
(жоғарыдағы қатені қараңыз, қайта іске қосуға болады), 2 модель жүктелмеді. Модельсіз тек кіші көшірмелер мен
360° сәйкестіктерін жасау үшін: `--without-models`.

## Сурет арқылы іздеу

Сатып алушы фото жібереді, сервер ұқсас тауарларды табады (`POST /api/v1/search/image`). Фото сақталмайды.
Әр тауардың негізгі фотосынан (фоны алынған нұсқасынан) вектор жасалады: пішін мен текстура
MobileNetV2-нің классификатор алдындағы қабатынан, түс аяқкиімнің өз пикселдерінің гистограммасынан.

| Модель | Лицензия | Дереккөз | SHA-256 |
| --- | --- | --- | --- |
| `mobilenetv2-12.onnx` | Apache-2.0, [ONNX Model Zoo](https://github.com/onnx/models) | https://media.githubusercontent.com/media/onnx/models/main/validated/vision/classification/mobilenet/model/mobilenetv2-12.onnx | `c0c3f76d93fa3fd6580652a45618618a220fced18babf65774ed169de0432ad5` |

```
export VITRINA_SEARCH_MODEL=models/mobilenetv2-12.onnx
VITRINA_SEARCH_MODEL=models/mobilenetv2-12.onnx python3 -m unittest tests.test_visual   # нақты модельмен тексеру
```
