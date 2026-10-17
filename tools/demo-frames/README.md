# Демо 360° кадрларын рендерлеу

```
curl -Lo shoe.glb https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/MaterialsVariantsShoe/glTF-Binary/MaterialsVariantsShoe.glb
npm pack three@0.160.0 && tar xzf three-0.160.0.tgz && mv package three160
node render.js . ./out 36      # Playwright + Chromium керек
```

Нәтиже: `out/<variant>/fNN.jpg`, 1200×1200. Лицензия мен авторы: `backend/demo/ATTRIBUTION.md`.
