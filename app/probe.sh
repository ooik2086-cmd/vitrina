#!/bin/bash
mkdir -p probe-out
adb logcat -c
(adb logcat -v time > probe-out/logcat.txt) &
(i=0; while true; do adb exec-out screencap -p > probe-out/s$(printf %03d $i).png 2>/dev/null; i=$((i+1)); sleep 1; done) &
flutter test integration_test/probe_test.dart -d emulator-5554 --dart-define=DEMO=true 2>&1 | tee probe-out/test.txt
sleep 2
kill %1 %2 2>/dev/null
grep -iE "exoplayer|mediacodec|video|chromium|3D stage" probe-out/logcat.txt | tail -200 > probe-out/logcat-focus.txt
true
