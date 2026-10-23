#!/bin/bash
# Start-rooktest (build 141): de gebouwde apps echt starten en een tijd laten draaien; bij een crash faalt de stap,
# met de crash-stack als ::error:: (zonder persoonsgegevens; het log is openbaar).
#
# Gebruik: tools/smoke_launch.sh <ios|tvos|macos> <map met de producten (Build/Products)> <uitvoermap>
#
# Per platform vier starts:
#   1. nieuwe installatie, gewone start (inlogscherm, zoals een nieuwe gebruiker)
#   2. nieuwe installatie met `-BingrSmoke YES`: terugkerende gebruiker (M3U-server met inloggegevens, profielen,
#      Mijn lijst); de app opent het profiel en loopt alle tabbladen langs (zie Shared/App/SmokeMode.swift)
#   3. opnieuw starten op dezelfde installatie (opgeslagen stand, migraties bij de tweede start)
#   4. nieuwe installatie met het kinderprofiel als laatst actieve profiel
# De M3U komt van een lokale testserver met verzonnen titels.
set -uo pipefail
PLATFORM=$1; PROD=$2; OUT=$3
SECS=${SMOKE_SECONDS:-28}
BUNDLE=nl.lrvdlinden.bingr
mkdir -p "$OUT"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$REPORTS"
FAIL=0

# lokale M3U-testserver
SRV="$OUT/m3u"; mkdir -p "$SRV"
python3 - "$SRV/get.php" <<'PY'
import sys
b = "http://127.0.0.1:8765"
l = ["#EXTM3U"]
for i in range(1, 13):
    g = "Smoke Kids" if i % 3 == 0 else "Smoke Live"
    l += [f'#EXTINF:-1 tvg-id="smoke{i}" tvg-name="Smoke {i}" tvg-logo="{b}/logo{i}.png" group-title="{g}",Smoke {i} HD',
          f"{b}/live/smoke/test/{i}.ts"]
for i in range(1, 25):
    g = "Kinderfilms" if i % 2 else "Smoke Films"
    l += [f'#EXTINF:-1 tvg-id="" tvg-name="Smoke Movie {i} ({2000 + i})" tvg-logo="{b}/poster{i}.jpg" group-title="{g}",Smoke Movie {i} ({2000 + i})',
          f"{b}/movie/smoke/test/{100 + i}.mp4"]
for s in range(1, 5):
    for e in range(1, 4):
        g = "Kids Series" if s % 2 else "Smoke Series"
        l += [f'#EXTINF:-1 tvg-id="" tvg-name="Smoke Show {s} S01E0{e}" tvg-logo="{b}/show{s}.jpg" group-title="{g}",Smoke Show {s} S01E0{e}',
              f"{b}/series/smoke/test/{1000 + s * 10 + e}.mp4"]
open(sys.argv[1], "w").write("\n".join(l) + "\n")
PY
( cd "$SRV" && exec python3 -m http.server 8765 --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV_PID=$!
trap 'kill $SRV_PID 2>/dev/null || true' EXIT
M3U="http://127.0.0.1:8765/get.php"

marker() { touch "$OUT/.mark"; sleep 1; }

# crashrapporten die na de marker zijn gemaakt (ook even wachten: ReportCrash schrijft met vertraging)
new_reports() {
  local wait=$1 found=""
  for _ in $(seq 1 "$wait"); do
    found=$(find "$REPORTS" -maxdepth 1 \( -name 'Bingr*.ips' -o -name 'BingrTV*.ips' -o -name 'Bingr*.crash' \) -newer "$OUT/.mark" 2>/dev/null)
    [ -n "$found" ] && break
    sleep 1
  done
  echo "$found"
}

report_crash() { # naam log
  local name=$1 log=$2 files
  files=$(new_reports 20)
  local summary="$OUT/$name.crash.txt"
  {
    echo "== $PLATFORM / $name: crash of vroegtijdig gestopt"
    if [ -n "$files" ]; then
      # shellcheck disable=SC2086
      python3 tools/smoke_crash.py $files
    else
      echo "(geen crashrapport gevonden)"
    fi
    echo "-- laatste regels van de app (Fatal error / BINGR_SMOKE):"
    grep -aE "BINGR_SMOKE|Fatal error|fatal error|Assertion failed|Precondition failed|Thread [0-9]+ Crashed|EXC_|SIG[A-Z]+" "$log" 2>/dev/null \
      | sed -E 's#/Users/[^/ ]+#~#g' | tail -n 25
  } > "$summary"
  cat "$summary"
  # één ::error:: per crash, met de stack (regeleinden als %0A)
  local msg; msg=$(head -c 6000 "$summary" | python3 -c "import sys; print(sys.stdin.read().replace('%','%25').replace('\r','').replace('\n','%0A'))")
  echo "::error title=Start-rooktest $PLATFORM ($name)::$msg"
  FAIL=1
}

# ---------- simulator (iOS / tvOS) ----------
runtime() { xcrun simctl list runtimes -j | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin)['runtimes'] if x['platform']=='$1' and x['isAvailable']]; print(sorted(r,key=lambda x:[int(p) for p in x['version'].split('.')])[-1]['identifier'])"; }
pick() { for t in "$@"; do if xcrun simctl list devicetypes | grep -q "^$t ("; then echo "$t"; return; fi; done; return 1; }

sim_run() { # udid app naam args...
  local udid=$1 app=$2 name=$3; shift 3
  local log="$OUT/$name.log"
  marker
  local out; out=$(xcrun simctl launch --terminate-running-process --stdout="$log" --stderr="$log" "$udid" "$BUNDLE" "$@" 2>&1)
  local pid; pid=$(echo "$out" | grep -oE '[0-9]+$' | tail -1)
  echo "$PLATFORM/$name: gestart (pid ${pid:-?})"
  if [ -z "$pid" ]; then echo "$out"; report_crash "$name" "$log"; return; fi
  local alive=1
  for s in $(seq 1 "$SECS"); do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; echo "$PLATFORM/$name: gestopt na ${s}s"; break; fi
  done
  if [ $alive = 1 ]; then
    # ook een crash van een hulpproces van de app telt
    local late; late=$(new_reports 1)
    if [ -n "$late" ]; then report_crash "$name" "$log"; return; fi
    echo "$PLATFORM/$name: draait na ${SECS}s nog (geen crash)"
    grep -a "BINGR_SMOKE" "$log" | tail -n 12 || true
    xcrun simctl io "$udid" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1 || true
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
  else
    report_crash "$name" "$log"
  fi
}

simulator() { # platform-runtime-naam app types...
  local rtname=$1 app=$2; shift 2
  local rt type udid
  rt=$(runtime "$rtname"); type=$(pick "$@") || { echo "::error::Geen simulator voor $rtname"; FAIL=1; return; }
  echo "Simulator: $type / $rt"
  udid=$(xcrun simctl create "smoke-$PLATFORM" "$type" "$rt")
  xcrun simctl boot "$udid"; xcrun simctl bootstatus "$udid" -b >/dev/null
  local fresh=(-AppleLanguages "(nl)" -AppleLocale nl_NL)
  xcrun simctl install "$udid" "$app"
  sim_run "$udid" "$app" 1-nieuw "${fresh[@]}"
  xcrun simctl uninstall "$udid" "$BUNDLE"; xcrun simctl install "$udid" "$app"
  sim_run "$udid" "$app" 2-terugkerend -BingrSmoke YES -BingrSmokeM3U "$M3U" "${fresh[@]}"
  sim_run "$udid" "$app" 3-herstart -BingrSmoke YES -BingrSmokeM3U "$M3U" "${fresh[@]}"
  xcrun simctl uninstall "$udid" "$BUNDLE"; xcrun simctl install "$udid" "$app"
  sim_run "$udid" "$app" 4-kinderprofiel -BingrSmoke YES -BingrSmokeKids YES -BingrSmokeM3U "$M3U" "${fresh[@]}"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
}

# ---------- Mac ----------
mac_run() { # naam args...
  local name=$1; shift
  local log="$OUT/$name.log" bin="$PROD/Debug/Bingr.app/Contents/MacOS/Bingr"
  marker
  "$bin" "$@" > "$log" 2>&1 &
  local pid=$!
  echo "macos/$name: gestart (pid $pid)"
  local alive=1
  for s in $(seq 1 "$SECS"); do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; echo "macos/$name: gestopt na ${s}s"; break; fi
  done
  if [ $alive = 1 ]; then
    local late; late=$(new_reports 1)
    kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null || true
    if [ -n "$late" ]; then report_crash "$name" "$log"; return; fi
    echo "macos/$name: draait na ${SECS}s nog (geen crash)"
    grep -a "BINGR_SMOKE" "$log" | tail -n 12 || true
    screencapture -x "$OUT/$name.png" 2>/dev/null || true
  else
    wait "$pid" 2>/dev/null; echo "exitcode $?"
    report_crash "$name" "$log"
  fi
}

mac_reset() { defaults delete "$BUNDLE" >/dev/null 2>&1 || true; rm -rf "$HOME/Library/Containers/$BUNDLE" "$HOME/Library/Application Support/$BUNDLE" 2>/dev/null || true; }

case "$PLATFORM" in
  ios)
    simulator iOS "$PROD/Debug-iphonesimulator/Bingr.app" "iPhone 16 Pro" "iPhone 17 Pro" "iPhone 16" "iPhone 15 Pro"
    ;;
  tvos)
    simulator tvOS "$PROD/Debug-appletvsimulator/BingrTV.app" "Apple TV 4K (3rd generation)" "Apple TV 4K (3rd generation) (at 1080p)" "Apple TV 4K (2nd generation)" "Apple TV"
    ;;
  macos)
    mac_reset
    mac_run 1-nieuw -AppleLanguages "(nl)"
    mac_reset
    mac_run 2-terugkerend -BingrSmoke YES -BingrSmokeM3U "$M3U" -AppleLanguages "(nl)"
    mac_run 3-herstart -BingrSmoke YES -BingrSmokeM3U "$M3U" -AppleLanguages "(nl)"
    mac_reset
    mac_run 4-kinderprofiel -BingrSmoke YES -BingrSmokeKids YES -BingrSmokeM3U "$M3U" -AppleLanguages "(nl)"
    mac_reset
    ;;
  *) echo "onbekend platform $PLATFORM"; exit 2 ;;
esac

if [ $FAIL = 0 ]; then echo "Start-rooktest $PLATFORM: geen crashes"; fi
exit $FAIL
