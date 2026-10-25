#!/usr/bin/env bash
# Builds the listing page's 3D stage into app/assets/viewer (and the staff console's copy): one script with three.js r160 inside (no CDN, so the
# stage opens on weak internet and offline), the page, and three.js's licence.
set -euo pipefail
cd "$(dirname "$0")"
npm ci --no-audit --no-fund
out=../../app/assets/viewer
mkdir -p "$out"
npx esbuild viewer.js --bundle --minify --format=iife --target=chrome80,safari14 --legal-comments=none --outfile="$out/viewer.js"
cp index.html "$out/index.html"
cp node_modules/three/LICENSE "$out/LICENSE-three.txt"
# The staff console draws a model's first picture with this same script, so it is the stage exactly as it opens.
cp "$out/viewer.js" ../../backend/vitrina_api/admin/viewer.js
