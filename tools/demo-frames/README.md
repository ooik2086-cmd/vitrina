# Демо 360° кадрларын рендерлеу

```
curl -Lo shoe.glb https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/MaterialsVariantsShoe/glTF-Binary/MaterialsVariantsShoe.glb
npm pack three@0.160.0 && tar xzf three-0.160.0.tgz && mv package three160
node render.js . ./out 36      # Playwright + Chromium керек
```

Нәтиже: `out/<variant>/fNN.jpg` және `top.jpg`, `sole.jpg`, `detail.jpg`, 1200×1200. Демо деректеріне қосу: `VITRINA_CUTOUT_MODEL=backend/models/isnet-general-use.onnx python3 app/demo/add_showcase.py`. Лицензия мен авторы: `backend/demo/ATTRIBUTION.md`.
