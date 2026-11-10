#!/bin/bash
# Runs the probe build (integration_test/probe_test.dart as the app) on its own and reads its prints from logcat.
mkdir -p probe-out/s
adb install -r build/app/outputs/flutter-apk/app-profile.apk
adb logcat -c
(adb logcat -v time > probe-out/logcat.txt) &
(while true; do adb exec-out screencap -p > probe-out/s/$(date +%H%M%S_%N | cut -c1-9).png 2>/dev/null; sleep 1; done) &
adb shell monkey -p kz.vitrina.vitrina -c android.intent.category.LAUNCHER 1
for i in $(seq 1 240); do
  sleep 5
  grep -q "PROBE DONE\|Test failed\|EXCEPTION CAUGHT" probe-out/logcat.txt && { sleep 5; break; }
done
kill %1 %2 2>/dev/null
grep -E "I/flutter|E/flutter" probe-out/logcat.txt > probe-out/test.txt
grep -iE "exoplayer|mediacodec|videoplayer|video_player|AndroidRuntime|FATAL" probe-out/logcat.txt | tail -300 > probe-out/logcat-focus.txt
cd probe-out/s && ls | awk 'NR%5!=0' | xargs rm -f
true
