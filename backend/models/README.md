# Фонды алып тастау моделі

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
Бар тауарларды өңдеу: `python3 scripts/cutout_backfill.py`.
