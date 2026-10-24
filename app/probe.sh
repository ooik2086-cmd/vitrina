#!/bin/bash
mkdir -p probe-out/s
adb logcat -c
(adb logcat -v time > probe-out/logcat.txt) &
(while true; do adb exec-out screencap -p > probe-out/s/$(date +%H%M%S_%N | cut -c1-9).png 2>/dev/null; sleep 0.4; done) &
flutter test integration_test/probe_test.dart -d emulator-5554 --dart-define=DEMO=true 2>&1 | tee probe-out/test.txt
sleep 2
kill %1 %2 2>/dev/null
grep -iE "exoplayer|mediacodec|videoplayer|video_player|3D stage|AndroidRuntime|FATAL" probe-out/logcat.txt | tail -300 > probe-out/logcat-focus.txt
for f in probe-out/s/*.png; do convert "$f" -resize 360x "${f%.png}.jpg" && rm "$f"; done
true
