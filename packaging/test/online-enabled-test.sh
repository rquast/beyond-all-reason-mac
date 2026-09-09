#!/bin/bash
# Feature: spec/features/online-play-enabled-remove-the-online-disable-machinery.feature
#
# online-enabled-test.sh — regression harness for the online-play enablement
# (LAUNCH-002). Asserts that the code which disabled connecting to the internet
# lobby is GONE from the packaging layer:
#   * release-build.sh exposes no --enable-online/--disable-online flags and
#     does not read BAR_ONLINE (so no build can steer the lobby at the old
#     unreachable loopback endpoint),
#   * the staged chobby_config.json keeps the canonical dist_cfg server
#     address+port verbatim (the extraction is now the only endpoint writer),
#   * launcher.sh + consent-dialog.swift + the test harnesses carry no
#     online-disabled notice machinery (marker gate, notice text, --notice
#     mode, ack file),
#   * the Makefile has no ONLINE wiring and the README no longer tells users
#     to build with online play disabled.
# No GUI, no network, no engine. Usage: packaging/test/online-enabled-test.sh
set -uo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$PKG/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
# NB both helpers MUST return 0: they sit mid-chain (`grep && bad || ok`), and
# a non-zero return cascades into the `||` branch.
ok()  { pass=$((pass+1)); printf "  ok   %s\n" "$1"; return 0; }
bad() { fail=$((fail+1)); printf "  FAIL %s\n" "$1"; [ -n "${2:-}" ] && printf "       %s\n" "${2:0:160}"; return 0; }

RB="$PKG/release-build.sh"
LS="$PKG/launcher.sh"
CD="$PKG/consent-dialog.swift"
LT="$PKG/test/launcher-test.sh"
DCT="$PKG/test/dialog-center-test.sh"
MK="$ROOT/Makefile"
RD="$ROOT/README.md"

# Hermetic arg-parse probe: copy release-build.sh next to a minimal
# ship-config.sh so it survives its pre-parse setup on ANY machine (the real
# one is maintainer-local) and then runs its argument parser for real.
# Writes to $PROBE_OUT, sets PROBE_RC (in the current shell — a command
# substitution subshell would not).
probe_args() { # probe_args <args...>
  local T="$WORK/argparse-$$"
  rm -rf "$T"; mkdir -p "$T/packaging"
  cp "$RB" "$T/packaging/release-build.sh"
  printf 'SHIP_ENGINE_BUILD="%s/build"\nSHIP_MESA_PREFIX="%s/mesa"\n' "$T" "$T" > "$T/packaging/ship-config.sh"
  # the script reads packaging/PORT_VERSION before its arg parser (under
  # set -e an empty cat aborts it) — copy the real one so parsing is reached
  cp "$PKG/PORT_VERSION" "$T/packaging/PORT_VERSION"
  # after a SUCCESSFUL arg parse the script enters step 1 (engine build); a
  # stub that fails with a unique code makes that path deterministic on any
  # machine (the probe only ever wants to observe the ARG PARSE result).
  mkdir -p "$T/scripts"
  printf '#!/bin/bash\nexit 42\n' > "$T/scripts/build-engine.sh"
  chmod +x "$T/scripts/build-engine.sh"
  PROBE_OUT="$WORK/argparse-out.txt"
  bash "$T/packaging/release-build.sh" "$@" > "$PROBE_OUT" 2>&1 </dev/null
  PROBE_RC=$?
  rm -rf "$T"
}

echo "== Scenario: A packaged build connects to the official lobby =="
# @step Given the bar-profile bundle is staged from the canonical dist_cfg launcher config
FIX="$WORK/dist_cfg"; mkdir -p "$FIX"
cat > "$FIX/config.json" <<'CFG'
{
  "json_files": {
    "chobby_config.json": {
      "server": { "address": "lobby.example.org", "port": 7008 },
      "game": "byar"
    }
  },
  "default_springsettings": { "Fullscreen": 1, "Water": 4 },
  "setups": [ { "downloads": { "games": [ "byar:test" ] } } ]
}
CFG
RES="$WORK/staged"; mkdir -p "$RES"
# @step When the launcher deploys chobby_config.json for a player session
# (the staging-time extraction is the launcher's deploy source; it is now the
#  ONLY writer of the lobby endpoint)
if python3 "$PKG/extract-launcher-config.py" "$FIX/config.json" "$RES" >/dev/null 2>&1; then
  # @step Then the deployed server address and port are exactly the ones from the canonical dist_cfg
  ADDR=$(python3 -c "import json;print(json.load(open('$RES/chobby_config.json'))['server']['address'])")
  PORT=$(python3 -c "import json;print(json.load(open('$RES/chobby_config.json'))['server']['port'])")
  [ "$ADDR" = "lobby.example.org" ] && [ "$PORT" = "7008" ] \
    && ok "staged endpoint == canonical dist_cfg (address=$ADDR port=$PORT)" \
    || bad "staged endpoint == canonical dist_cfg" "got: $ADDR:$PORT"
  # @step And the lobby server endpoint is not the unreachable loopback endpoint online-play-disabled.localhost:1
  [ "$ADDR" != "online-play-disabled.localhost" ] && [ "$PORT" != "1" ] \
    && ok "endpoint is not the neutered loopback (online-play-disabled.localhost:1)" \
    || bad "endpoint is not the neutered loopback" "got: $ADDR:$PORT"
  # @step And the staged Resources contain no .online-play-disabled marker file
  [ ! -e "$RES/.online-play-disabled" ] \
    && ok "staging writes no .online-play-disabled marker" \
    || bad "staging writes no .online-play-disabled marker"
else
  bad "extract-launcher-config.py ran on the fixture dist_cfg"
  bad "staged endpoint == canonical dist_cfg" "extraction failed"
  bad "endpoint is not the neutered loopback" "extraction failed"
  bad "staging writes no .online-play-disabled marker" "extraction failed"
fi

echo "== Scenario: First launch of a packaged build shows no online-disabled notice =="
# Compact launcher driver (same recording-stub technique as
# launcher-test.sh): a fake bundle whose helpers log their invocations,
# driven through the REAL launcher.sh. No GUI, no network, no engine.
FAKE="$WORK/app/BAR Launcher.app"
F_MACOS="$FAKE/Contents/MacOS"; F_RES="$FAKE/Contents/Resources"
mkdir -p "$F_MACOS" "$F_RES/vulkan/icd.d"
F_CALLS="$WORK/calls.log"
export F_CALLS
cp "$LS" "$F_MACOS/launcher"; chmod +x "$F_MACOS/launcher"
# hermetic PATH: tmutil talks to backupd and can hang; osascript pops real GUI
# dialogs — stub both so the run never depends on machine state
F_BIN="$WORK/bin"; mkdir -p "$F_BIN"
printf '#!/bin/bash\nexit 0\n' > "$F_BIN/tmutil"; chmod +x "$F_BIN/tmutil"
printf '#!/bin/bash\necho "osascript" >> "$F_CALLS"; exit 0\n' > "$F_BIN/osascript"; chmod +x "$F_BIN/osascript"
cat > "$F_MACOS/message-check" <<'S'
#!/bin/bash
echo "message-check" >> "$F_CALLS"; exit 0
S
cat > "$F_MACOS/consent-dialog" <<'S'
#!/bin/bash
case "$*" in
  *--server*) echo "consent-server" >> "$F_CALLS"; exit 0;;
  *) echo "consent-unknown" >> "$F_CALLS"; echo "  (args: $*)" >> "$F_CALLS"; exit 1;;
esac
S
cat > "$F_MACOS/spring" <<'S'
#!/bin/bash
echo "spring-launched" >> "$F_CALLS"; exit 0
S
cat > "$F_MACOS/error-dialog" <<'S'
#!/bin/bash
echo "error-dialog" >> "$F_CALLS"; exit 0
S
cat > "$F_MACOS/progress-window" <<'S'
#!/bin/bash
echo "progress-window" >> "$F_CALLS"; cat > /dev/null; exit 0
S
chmod +x "$F_MACOS/message-check" "$F_MACOS/consent-dialog" "$F_MACOS/spring" \
  "$F_MACOS/error-dialog" "$F_MACOS/progress-window"
cat > "$F_RES/download-content.sh" <<'S'
#!/bin/bash
case "$*" in *--print-server*) echo "repos-cdn.beyondallreason.dev"; exit 0;; esac
printf '@S go\n@DONE\n'; exit 0
S
chmod +x "$F_RES/download-content.sh"
echo '{}' > "$F_RES/chobby_config.json"
printf 'byar:test\nbyar-chobby:test\n' > "$F_RES/content_tags"
echo '{}' > "$F_RES/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
cat > "$FAKE/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.1</string></dict></plist>
P
# @step Given a fresh machine writedir and a bundle whose Resources still carry the legacy .online-play-disabled marker
F_WD="$WORK/writedir"; mkdir -p "$F_WD"
: > "$F_RES/.online-play-disabled"   # legacy marker: shipped in old builds; must be IGNORED now
: > "$F_CALLS"
# @step When a player launches the game for the first time
PATH="$F_BIN:$PATH" BAR_WRITEDIR_OVERRIDE="$F_WD" "$F_MACOS/launcher" >/dev/null 2>&1 </dev/null
# @step Then the "ONLINE PLAY IS DISABLED" notice is not shown and no .notice-ack file is written
grep -q 'consent-unknown' "$F_CALLS" \
  && bad "no online-disabled notice dialog (legacy marker ignored)" "calls: $(tr '\n' ',' < "$F_CALLS")" \
  || ok "no online-disabled notice dialog (legacy marker ignored)"
[ ! -e "$F_WD/.notice-ack" ] \
  && ok "no .notice-ack file written (notice machinery gone)" \
  || bad "no .notice-ack file written (notice machinery gone)"
# @step And the remote message check still runs
grep -q '^message-check$' "$F_CALLS" \
  && ok "remote message check still runs" || bad "remote message check still runs"
# @step And the content-disclaimer still runs
grep -q '^consent-server$' "$F_CALLS" \
  && ok "content disclaimer still runs" || bad "content disclaimer still runs"
# @step And the engine launches
grep -q '^spring-launched$' "$F_CALLS" \
  && ok "engine launched" || bad "engine launched"

echo "== Scenario: The build pipeline has no online-disable switch =="
# @step Given the build pipeline is the packaged Makefile and release-build.sh
# @step When the maintainer builds the app with plain `make app` and never mentions online play
probe_args
# @step Then a plain invocation of release-build.sh is accepted as usual and proceeds to the engine build step
[ "$PROBE_RC" = 42 ] \
  && ok "plain invocation parses and reaches the engine-build step (stub exit 42)" \
  || bad "plain invocation parses" "rc=$PROBE_RC out: $(cat "$PROBE_OUT" 2>/dev/null)"
# @step And release-build.sh rejects --enable-online and --disable-online as unknown arguments
probe_args --disable-online
[ "$PROBE_RC" = 2 ] && { case "$(cat "$PROBE_OUT")" in *"unknown arg: --disable-online"*) true;; *) false;; esac; } \
  && ok "--disable-online refused (unknown arg, exit 2)" \
  || bad "--disable-online refused" "rc=$PROBE_RC out: $(cat "$PROBE_OUT" 2>/dev/null)"
probe_args --enable-online
[ "$PROBE_RC" = 2 ] && { case "$(cat "$PROBE_OUT")" in *"unknown arg: --enable-online"*) true;; *) false;; esac; } \
  && ok "--enable-online refused (unknown arg, exit 2)" \
  || bad "--enable-online refused" "rc=$PROBE_RC out: $(cat "$PROBE_OUT" 2>/dev/null)"
# @step And the BAR_ONLINE environment variable has no effect
grep -q 'BAR_ONLINE' "$RB" \
  && bad "release-build.sh no longer reads BAR_ONLINE" \
  || ok "release-build.sh no longer reads BAR_ONLINE"
# its tell-tale string is the loopback host — no neuter block may remain
grep -q 'online-play-disabled\.localhost' "$RB" \
  && bad "loopback-endpoint neuter block still present in release-build.sh" \
  || ok "no loopback-endpoint neuter block in release-build.sh"
# @step And the Makefile documents no ONLINE variable
grep -q 'ONLINE' "$MK" \
  && bad "Makefile: ONLINE variable/wiring still present" \
  || ok "Makefile: no ONLINE variable or flag wiring"
# @step And the README no longer instructs building with online play disabled
grep -qi 'online play disabled' "$RD" \
  && bad "README still instructs building with online play disabled" \
  || ok "README no longer mentions online play being disabled"

echo "== Scenario: The online-disabled notice machinery is gone from the launcher =="
# @step Given the launcher source and its test harnesses
# @step When the maintainer inspects the packaging layer
# @step Then launcher.sh contains no marker gate, notice text, or .notice-ack machinery
for pat in '\.online-play-disabled' 'NOTICE_VERSION' 'notice-ack' 'ONLINE PLAY IS DISABLED'; do
  grep -q "$pat" "$LS" \
    && bad "launcher.sh: pattern '$pat' still present" \
    || ok "launcher.sh: no '$pat'"
done
# the two surviving pre-game dialogs must stay put
grep -q -- '--server' "$LS" \
  && ok "launcher.sh: content-disclaimer (--server) path intact" \
  || bad "launcher.sh: content-disclaimer path intact"
grep -q 'message-check' "$LS" \
  && ok "launcher.sh: remote message-check path intact" \
  || bad "launcher.sh: remote message-check path intact"
# @step And consent-dialog.swift has no --notice mode
grep -q -- '--notice' "$CD" \
  && bad "consent-dialog.swift: --notice mode still present" \
  || ok "consent-dialog.swift: no --notice mode"
if swiftc -version >/dev/null 2>&1; then
  if swiftc -parse "$CD" >/dev/null 2>&1; then
    ok "consent-dialog.swift parses"
  else
    bad "consent-dialog.swift parses"
  fi
else
  echo "  skip consent-dialog.swift parses (swiftc unavailable — e.g. Xcode license)"
fi
# @step And launcher-test.sh has no case gating a notice on the marker
grep -qE 'online_on|online_off|: > "\$RES/\.online-play-disabled"' "$LT" \
  && bad "launcher-test.sh: marker-gated notice case still present" \
  || ok "launcher-test.sh: no marker-gated notice case"
# @step And dialog-center-test.sh has no online-disabled notice geometry case
grep -q 'check "online-disabled notice"' "$DCT" \
  && bad "dialog-center-test.sh: online-disabled geometry case still present" \
  || ok "dialog-center-test.sh: no online-disabled geometry case"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
