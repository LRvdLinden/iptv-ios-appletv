#!/bin/bash
# Start-rooktest (build 141): de gebouwde apps echt starten en een tijd laten draaien; bij een crash faalt de stap,
# met de crash-stack als ::error:: (zonder persoonsgegevens; het log is openbaar).
#
# Gebruik: tools/smoke_launch.sh <ios|tvos|macos> <map met de producten (Build/Products)> <uitvoermap>
#
# Per platform vier starts:
#   1. nieuwe installatie, gewone start (inlogscherm, zoals een nieuwe gebruiker)
#   2. nieuwe installatie met `-BingrSmoke YES` (sleutelhanger 150 ms trager, zoals op een toestel): terugkerende gebruiker (M3U-server met inloggegevens, profielen,
#      Mijn lijst); de app opent het profiel en loopt alle tabbladen langs (zie Shared/App/SmokeMode.swift)
#   3. opnieuw starten op dezelfde installatie (opgeslagen stand, migraties bij de tweede start)
#   4. nieuwe installatie met het kinderprofiel als laatst actieve profiel
# De M3U komt van een lokale testserver met verzonnen titels.
set -uo pipefail
PLATFORM=$1; PROD=$2; OUT=$3
SECS=${SMOKE_SECONDS:-75}
# build 142: korte rooktest bij elke push (SMOKE_LIGHT=1): kleine servers, alleen een nieuwe en een terugkerende start
if [ -n "${SMOKE_LIGHT:-}" ]; then SECS=${SMOKE_SECONDS:-40}; SMOKE_BIG_MOVIES=${SMOKE_BIG_MOVIES:-400}; SMOKE_BIG_SHOWS=${SMOKE_BIG_SHOWS:-60}; unset SMOKE_EMAIL; fi
BUNDLE=nl.lrvdlinden.bingr
mkdir -p "$OUT"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$REPORTS"
FAIL=0

# lokale M3U-testserver: get.php (klein, de open server) en get2.php/get3.php (groot: veel titels over alle servers)
SRV="$OUT/m3u"; mkdir -p "$SRV"
make_m3u() { # bestand films series voorvoegsel extra
  python3 - "$@" <<'PY'
import sys
path, movies, shows, pre, extra = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
b = "http://127.0.0.1:8765"
l = ["#EXTM3U"]
for i in range(1, 13):
    g = "Smoke Kids" if i % 3 == 0 else "Smoke Live"
    l += [f'#EXTINF:-1 tvg-id="{pre}{i}" tvg-name="{pre} {i}" tvg-logo="{b}/logo{i}.png" group-title="{g}",{pre} {i} HD',
          f"{b}/live/smoke/test/{pre}{i}.ts"]
for i in range(1, movies + extra + 1):
    g = ["Kinderfilms", "Smoke Films", "Actie", "Drama", "Komedie"][i % 5]
    l += [f'#EXTINF:-1 tvg-id="" tvg-name="{pre} Movie {i} ({1950 + i % 75})" tvg-logo="{b}/p/{pre}{i}.jpg" group-title="{g}",{pre} Movie {i} ({1950 + i % 75})',
          f"{b}/movie/smoke/test/{pre}{100000 + i}.mp4"]
for s in range(1, shows + 1):
    g = "Kids Series" if s % 2 else "Smoke Series"
    for e in range(1, 5):
        l += [f'#EXTINF:-1 tvg-id="" tvg-name="{pre} Show {s} S01E0{e}" tvg-logo="{b}/s/{pre}{s}.jpg" group-title="{g}",{pre} Show {s} S01E0{e}',
              f"{b}/series/smoke/test/{pre}{s * 10 + e}.mp4"]
open(path, "w").write("\n".join(l) + "\n")
PY
}
make_m3u "$SRV/get.php" 40 6 Smoke 0
make_m3u "$SRV/get2.php" "${SMOKE_BIG_MOVIES:-50000}" "${SMOKE_BIG_SHOWS:-6000}" Groot 0
make_m3u "$SRV/get3.php" "${SMOKE_BIG_MOVIES:-50000}" "${SMOKE_BIG_SHOWS:-6000}" Reus 0
ls -la "$SRV" | awk '{print $5, $9}' | tail -n 3
( cd "$SRV" && exec python3 -m http.server 8765 --bind 127.0.0.1 ) > /dev/null 2> "$OUT/m3u-access.log" &
SRV_PID=$!
trap 'kill $SRV_PID 2>/dev/null || true' EXIT
# tweede start: nieuwe titels op de open server (Nieuw op Bingr, billboard)
more_titles() { make_m3u "$SRV/get.php" 40 6 Smoke 12; }
M3U="http://127.0.0.1:8765/get"

count_req() { local n; n=$(grep -c 'GET /get' "$OUT/m3u-access.log" 2>/dev/null); echo "${n:-0}"; }

marker() { touch "$OUT/.mark"; sleep 1; }

# crashrapporten die na de marker zijn gemaakt (ook even wachten: ReportCrash schrijft met vertraging)
new_reports() {
  local wait=$1 found=""
  for _ in $(seq 1 "$wait"); do
    # bewuste crash van de test (StartDiagnostics.forceCrash) telt niet
    found=$(find "$REPORTS" -maxdepth 1 \( -name 'Bingr*.ips' -o -name 'BingrTV*.ips' -o -name 'Bingr*.crash' \) -newer "$OUT/.mark" \
      -exec grep -L "forceCrash" {} + 2>/dev/null)
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

# piekgeheugen (RSS) van de app; boven SMOKE_MAX_MB (tvOS: ruim onder de grens van een Apple TV) faalt de test,
# want op het apparaat stopt het systeem de app dan (lijkt een crash direct na het openen)
# build 143: pincodescherm te laat (BINGR_SMOKE_FAIL) of de hoofdthread langer dan 5 s vast = fout (op een toestel
# stopt de watchdog de app dan, 0x8badf00d)
check_log() { # naam log
  local bad
  bad=$(grep -aE "BINGR_SMOKE_FAIL|hoofdthread hing ([5-9]|[1-9][0-9]+)\.[0-9] s" "$2" | sed -E 's/^.*BINGR_SMOKE: //' | head -5)
  if [ -n "$bad" ]; then
    echo "::error title=Start-rooktest $PLATFORM ($1)::$(echo "$bad" | tr '\n' ' ')"
    FAIL=1
  fi
}

check_memory() { # naam piek-kB
  local mb=$(( $2 / 1024 ))
  echo "$PLATFORM/$1: piekgeheugen ${mb} MB"
  if [ -n "${SMOKE_MAX_MB:-}" ] && [ "$mb" -gt "$SMOKE_MAX_MB" ]; then
    echo "::error title=Start-rooktest $PLATFORM ($1)::Piekgeheugen ${mb} MB boven ${SMOKE_MAX_MB} MB (op het apparaat stopt het systeem de app)"
    FAIL=1
  fi
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
  local alive=1 peak=0 rss secs=$SECS timeline="" req0
  [ "$name" = 1-nieuw ] && secs=15
  [ "$name" = 2b-crash ] && secs=25
  req0=$(count_req); local t0=$(date +%s) reqchecked=0
  for s in $(seq 1 "$secs"); do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; echo "$PLATFORM/$name: gestopt na ${s}s"; break; fi
    # build 143: start met een bewaarde lijst: de eerste 30 s geen enkele aanvraag naar de IPTV-servers
    if [ $reqchecked = 0 ] && [ $(( $(date +%s) - t0 )) -ge 29 ] && [ "${CACHED_START:-}" = 1 ]; then
      reqchecked=1
      local reqs=$(( $(count_req) - req0 ))
      echo "$PLATFORM/$name: aanvragen naar de servers in de eerste 30 s: $reqs"
      [ "$reqs" -gt 0 ] && grep 'GET /get' "$OUT/m3u-access.log" | tail -n "$reqs" | sed -E "s|^[^[]*|$PLATFORM/$name: aanvraag: |; s|\\?[^ ]*||"
      if [ "$reqs" -gt 0 ]; then echo "::error title=Start-rooktest $PLATFORM ($name)::$reqs aanvragen naar de IPTV-servers in de eerste 30 s na een start met bewaarde lijst"; FAIL=1; fi
    fi
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' '); [ -n "$rss" ] && [ "$rss" -gt "$peak" ] && peak=$rss
    [ -n "$rss" ] && [ $((s % 5)) = 0 ] && timeline="$timeline ${s}s:$((rss / 1024))"
  done
  echo "$PLATFORM/$name: geheugen (MB) per 5 s:$timeline"
  check_memory "$name" "$peak"
  check_log "$name" "$log"
  if [ -n "${EXPECT_CRASH:-}" ]; then
    # build 143: bewuste crash (test van de startdiagnose): moet gestopt zijn, geen fout
    if [ $alive = 1 ]; then echo "::error title=Start-rooktest $PLATFORM ($name)::bewuste crash gebeurde niet"; FAIL=1
    else echo "$PLATFORM/$name: bewust gecrasht (verwacht)"; new_reports 25 >/dev/null; sleep 2; fi
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
    return
  fi
  if [ $alive = 1 ]; then
    # ook een crash van een hulpproces van de app telt
    local late; late=$(new_reports 1)
    if [ -n "$late" ]; then report_crash "$name" "$log"; return; fi
    echo "$PLATFORM/$name: draait na ${secs}s nog (geen crash)"
    grep -a "BINGR_SMOKE" "$log" | grep -v "tabblad" | tail -n 20 || true
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
  sim_run "$udid" "$app" 2-terugkerend -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeM3U "$M3U" "${fresh[@]}"
  # build 143: bewuste crash → de volgende start moet het rapport van de startdiagnose hebben
  EXPECT_CRASH=1 sim_run "$udid" "$app" 2b-crash -BingrSmoke YES -BingrSmokeCrash YES -BingrSmokeM3U "$M3U" "${fresh[@]}"
  CACHED_START=1 sim_run "$udid" "$app" 2c-na-crash -BingrSmoke YES -BingrSmokeExpectCrashReport YES -BingrSmokeM3U "$M3U" "${fresh[@]}"
  if [ -n "${SMOKE_LIGHT:-}" ]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    return
  fi
  more_titles
  CACHED_START=1 sim_run "$udid" "$app" 3-herstart -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeM3U "$M3U" "${fresh[@]}"
  xcrun simctl uninstall "$udid" "$BUNDLE"; xcrun simctl install "$udid" "$app"
  make_m3u "$SRV/get.php" 40 6 Smoke 0
  sim_run "$udid" "$app" 4-kinderprofiel -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeKids YES -BingrSmokeM3U "$M3U" "${fresh[@]}"
  if [ -n "${SMOKE_EMAIL:-}" ]; then
    # met een Bingr-account (tijdelijk testaccount): de iPhone zet zijn gegevens in het account, de Apple TV (en de Mac)
    # haalt alles van het account, zoals een gebruiker die op een tweede apparaat inlogt; daarna opnieuw starten met
    # de sessie (de account-sync bij het starten)
    xcrun simctl uninstall "$udid" "$BUNDLE"; xcrun simctl install "$udid" "$app"
    if [ "$PLATFORM" = ios ]; then
      sim_run "$udid" "$app" 5-account -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeM3U "$M3U" -BingrSmokeEmail "$SMOKE_EMAIL" -BingrSmokePassword "$SMOKE_PASSWORD" "${fresh[@]}"
    else
      sim_run "$udid" "$app" 5-account -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeNoSeed YES -BingrSmokeEmail "$SMOKE_EMAIL" -BingrSmokePassword "$SMOKE_PASSWORD" "${fresh[@]}"
    fi
    sim_run "$udid" "$app" 6-account-herstart -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeEmail "$SMOKE_EMAIL" -BingrSmokePassword "$SMOKE_PASSWORD" "${fresh[@]}"
  fi
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
  local alive=1 peak=0 rss secs=$SECS timeline=""
  [ "$name" = 1-nieuw ] && secs=15
  [ "$name" = 2b-crash ] && secs=25
  for s in $(seq 1 "$secs"); do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; echo "macos/$name: gestopt na ${s}s"; break; fi
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' '); [ -n "$rss" ] && [ "$rss" -gt "$peak" ] && peak=$rss
    [ -n "$rss" ] && [ $((s % 5)) = 0 ] && timeline="$timeline ${s}s:$((rss / 1024))"
  done
  echo "$PLATFORM/$name: geheugen (MB) per 5 s:$timeline"
  check_memory "$name" "$peak"
  check_log "$name" "$log"
  if [ $alive = 1 ]; then
    local late; late=$(new_reports 1)
    kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null || true
    if [ -n "$late" ]; then report_crash "$name" "$log"; return; fi
    echo "macos/$name: draait na ${secs}s nog (geen crash)"
    grep -a "BINGR_SMOKE" "$log" | grep -v "tabblad" | tail -n 20 || true
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
    simulator tvOS "$PROD/${SMOKE_CONFIG:-Debug}-appletvsimulator/BingrTV.app" "Apple TV 4K (3rd generation)" "Apple TV 4K (3rd generation) (at 1080p)" "Apple TV 4K (2nd generation)" "Apple TV"
    ;;
  macos)
    mac_reset
    mac_run 1-nieuw -AppleLanguages "(nl)"
    mac_reset
    mac_run 2-terugkerend -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeM3U "$M3U" -AppleLanguages "(nl)"
    more_titles
    mac_run 3-herstart -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeM3U "$M3U" -AppleLanguages "(nl)"
    mac_reset
    make_m3u "$SRV/get.php" 40 6 Smoke 0
    mac_run 4-kinderprofiel -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeKids YES -BingrSmokeM3U "$M3U" -AppleLanguages "(nl)"
    mac_reset
    if [ -n "${SMOKE_EMAIL:-}" ]; then
      mac_run 5-account -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeNoSeed YES -BingrSmokeEmail "$SMOKE_EMAIL" -BingrSmokePassword "$SMOKE_PASSWORD" -AppleLanguages "(nl)"
      mac_run 6-account-herstart -BingrSmoke YES -BingrSmokeKeychainMs "${SMOKE_KEYCHAIN_MS:-150}" -BingrSmokeEmail "$SMOKE_EMAIL" -BingrSmokePassword "$SMOKE_PASSWORD" -AppleLanguages "(nl)"
      mac_reset
    fi
    ;;
  *) echo "onbekend platform $PLATFORM"; exit 2 ;;
esac

if [ $FAIL = 0 ]; then echo "Start-rooktest $PLATFORM: geen crashes"; fi
exit $FAIL
