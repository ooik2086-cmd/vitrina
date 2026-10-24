#!/bin/bash
# Drives the published demo APK (what Aza has) with plain taps: open the first card, the Видео tab, play.
mkdir -p probe-out/r
gh release download demo -R "$GITHUB_REPOSITORY" -p vitrina-demo-x86_64.apk -O demo.apk
adb install -r demo.apk
adb logcat -c
(adb logcat -v time > probe-out/r-logcat.txt) &
shot() { adb exec-out screencap -p > probe-out/r/$1.png; }
adb shell monkey -p kz.vitrina.vitrina -c android.intent.category.LAUNCHER 1
sleep 20; shot 01-catalog
adb shell input swipe 160 500 160 300 400; sleep 3; shot 02-scrolled
adb shell input tap 80 300; sleep 1; shot 03-open1s
sleep 4; shot 04-open5s
sleep 10; shot 05-open15s
adb shell input tap 255 432; sleep 2; shot 06-videotab
adb shell input tap 160 200; sleep 1; shot 07-play1s
sleep 3; shot 08-play4s
sleep 4; shot 09-play8s
sleep 4; shot 10-play12s
kill %1 2>/dev/null
grep -iE "exoplayer|mediacodec|videoplayer|video_player|AndroidRuntime|FATAL|flutter" probe-out/r-logcat.txt | tail -300 > probe-out/r-logcat-focus.txt
true
