# AST research — online-disable machinery (LAUNCH-002)

Discovery sweep for every site that disables or announces the disabling of
internet (lobby) play in the BAR macOS packaging layer. Grep + AST search over
`packaging/`, `Makefile`, `README.md`, `docs/`. No sim code involved; all
sites are build/packaging scripts + Swift helpers + their test harnesses.

## Removal sites (the feature's scope)

### packaging/release-build.sh (build-time neutering)
- L75-89: `ENABLE_ONLINE="${BAR_ONLINE:-0}"` — the knob (default 0 = disabled,
  "a standing rule" per the comment; the rule this story deletes).
- L127: `--enable-online) ENABLE_ONLINE=1;`
- L128: `--disable-online) ENABLE_ONLINE=0;`
- L349-371: the neuter block — Python heredoc `NEUTER` rewrites
  `Resources/chobby_config.json` `server.address` to
  `online-play-disabled.localhost` and `server.port` to `1`;
  `touch "$RESOURCES/.online-play-disabled"` marker;
  "online play: DISABLED/ENABLED" log lines.
- L88: doc pointer to `docs/OUTSTANDING.md` (no longer exists in this tree).

### packaging/launcher.sh (runtime notice)
- L236: `NOTICE_VERSION="1"`
- L238: `NOTICE_ACK="$WRITEDIR/.notice-ack"`
- L275-286: gate — `if [ -f "$RES/.online-play-disabled" ] && ... != NOTICE_VERSION`
  → `consent-dialog --notice "ONLINE PLAY IS DISABLED ... while I seek
  approval from the creators of Beyond All Reason ..."` + ack write.
  Sits between the remote message-check and the content-disclaimer; only the
  `# 2)` item goes. `# 3)` consent/disclaimer numbering shifts to `# 2)`.

### packaging/consent-dialog.swift
- L11-12: header comment documents `--notice` mode ("e.g. online play disabled").
- L84-101: `if let notice = arg("--notice")` branch — builds the informational
  NSAlert with the "— Ben" signature accessory, OK button, exit 0.
  The ONLY caller of `--notice` in the tree is launcher.sh L278 (verified by
  grep), so the branch is dead code once that call is removed.

### Makefile
- L29: `ONLINE ?=`
- L32: `ONLINE_ARG := $(if $(filter 0,$(ONLINE)),--disable-online,)`
- L47: help line `ONLINE=0 make ... disable online play (enabled by default)`
- L50/L56/L64: `$(ONLINE_ARG)` in `app`, `certify`, `release` targets.

### README.md
- L211-217: "Released builds currently ship with online play disabled ...
  while approval to connect to BAR's community servers is sought ... pass
  `ONLINE=0` ..." — the user-facing note.

### Test harnesses
- packaging/test/launcher-test.sh:
  - L37: consent-dialog stub `*--notice*) consent-notice` case.
  - L86-87: `online_on()` / `online_off()` marker helpers.
  - L90 `online_on;` in the first-run test; L94 `.notice-ack written` assert;
    L98 `! has consent-notice` assert; L107 `.notice-ack` reset in the bump
    test; L109/L111 `consent-notice` asserts;
    L122-126 "online-disabled marker gates the notice" section;
    L130/L133 assume-consent/skip asserts include `! has consent-notice`.
  - L6: header comment mentions "the online-disabled marker".
- packaging/test/dialog-center-test.sh:
  - L12: bug-history comment mentioning the online-disabled dialog (keep —
    it's history, not behavior; the geometry check it names is gone though).
  - L104-106: `check "online-disabled notice" ... --notice "ONLINE PLAY IS
    DISABLED ..."` geometry case — the only consumer of `--notice` in tests.
- packaging/extract-launcher-config.py: no changes (it is the ONLY writer of
  the lobby endpoint; the neuter block was the other writer).

## Untouched by design
- `message-config/messages.json` + `message-check.swift`: remote message
  system (announcements/kill-switch) — orthogonal to online play.
- `docs/MAINTENANCE.md` L77-83: release-process rule "cap the online-disabled
  messaging when online play is enabled" — process doc; the repo keeps it as
  standing guidance, no code change needed.
- Engine networking (direct/LAN) was never touched by the disable machinery
  (release-build.sh comment L83-84 confirms).
- `chobby/dist_cfg` — untracked local clone (gitignored), the canonical
  endpoint source; not part of the change.

## Verification plan (test-first)
1. `packaging/test/launcher-test.sh` (real launcher, stubbed helpers):
   first-run sequence = message-check + consent-server only; no consent-notice
   call; no `.notice-ack` written; `.online-play-disabled` marker in a bundle
   has NO effect (launcher ignores it); version-bump, quit, kill-switch,
   assume-consent cases preserved.
2. `packaging/test/dialog-center-test.sh`: online-disabled geometry case
   removed; consent-dialog no longer accepts `--notice` (passing it = no
   alert / refused argument → the download-consent path is the only mode).
3. New staging assertion (bash): simulate the release-build.sh bar-profile
   staging section against a fixture dist_cfg; staged `chobby_config.json`
   `server.address`/`port` must equal the fixture values verbatim;
   `release-build.sh --disable-online` / `--enable-online` → `unknown arg`,
   exit 2; `BAR_ONLINE=1` → no effect.
4. `make -n app ONLINE=0` must not fail from unknown make vars (make vars are
   free), but the help text no longer documents it; Makefile has no ONLINE.
5. `bash -n` on every edited script; `swiftc -parse` on consent-dialog.swift.
