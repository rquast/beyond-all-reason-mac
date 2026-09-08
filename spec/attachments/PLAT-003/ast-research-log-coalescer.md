# AST research: log repeat-coalescer (PLAT-003)

Scope: `rts/System/Log/` — the logging choke point the coalescer plugs into, and
its call sites / related subsystems. Collected 2026-09-08 during PLAT-003
discovery.

## Entry point: `log_backend_record` (Backend.cpp:198)

```
void log_backend_record(int level, const char* section, const char* fmt, va_list arguments)
```

- Formats the record via `log_formatter_format` (DefaultFormatter.cpp:78).
- First applies exact-duplicate suppression: if the message matches
  `prv_record.msg` and the repeat limit (`log_filter_getRepeatLimit`,
  DefaultFilter.cpp:102) is exceeded, the record is dropped before the
  coalescer ever sees it. This is why the unit tests set the repeat limit to 0
  (`RepeatLimitGuard`) to exercise near-identical (numeric-varying) lines.
- Then runs the generic coalescer (below) and, for a passing record,
  `log_formatter::emit_to_sinks(level, section, cur_record.msg)` — the same
  call used for rollups, so rollups go through every sink too.

## Coalescer core: `namespace log_coalesce` (Backend.cpp:90–173)

| Symbol | Location | Role |
|---|---|---|
| `ROLLUP_EVERY = 100` | Backend.cpp:103 | Suppress this many before a periodic rollup |
| `NUM_SLOTS = 8` | Backend.cpp:110 | Concurrent distinct flood patterns tracked |
| `Slot { sig[512], section[64], level, sinceRollup, seq, used }` | Backend.cpp:112 | One tracked pattern |
| `slots[8]`, `seqCounter`, `mutex` | Backend.cpp:122 | Process-global, guarded by mutex |
| `MakeSig(section, msg, out, outSz)` | Backend.cpp:135 | Section + message, each digit-run (with internal `.-,+` separators) collapsed to `#`; punctuation-only runs kept verbatim |
| `FormatRollup(buf, bufSz, n, section)` | Backend.cpp:165 | `[log] previous line repeated %llu more time(s) [section: %s]` |

Flow in `log_backend_record`:
1. `MakeSig` → lookup match among 8 slots.
2. **Match**: suppress (`emitRecord = false`), `++sinceRollup`; when
   `sinceRollup >= ROLLUP_EVERY` format a rollup, reset counter.
3. **No match**: pass through in full; claim a free slot else LRU-evict
   (`seq`); if the evicted slot has a pending tail, flush it (emit that
   rollup first) so no count is lost.
4. Rollup and record emits both happen **outside** the mutex (decisions under
   lock, emits after) — a re-entrant sink (e.g. FileSink logging a failed
   fopen) cannot deadlock.

## Tail flush: `log_backend_flushRepeats` (Backend.cpp:295)

Snapshots every slot with `sinceRollup > 0` under the lock, then emits one
rollup per pending pattern outside the lock. Public in `Backend.h:48`. Called
by `log_backend_cleanup` (Backend.cpp:318), i.e. at `LOG_CLEANUP()` and at
normal shutdown — so the residual tail of every flood is accounted for.

## Related functions (unchanged, for context)

- `log_backend_registerSink` / `_unregisterSink` — Backend.cpp:184/185; the
  tests register a capture sink through this.
- `log_filter_setRepeatLimit` / `log_filter_getRepeatLimit` —
  DefaultFilter.cpp:102/103; exact-duplicate limit (default 1) lives on the
  filter side, independent of the coalescer.
- `log_frontend_record` — DefaultFilter.cpp:294; front-door that filters
  (min level, enabled) before `log_backend_record`.
- Sinks: ConsoleSink.cpp:38, FileSink.cpp:292, StreamSink.cpp:29,
  TracySink.cpp:12, OutputDebugStringSink.cpp:28, LogSinkHandler.cpp:12 — all
  receive (level, section, record) from `emit_to_sinks`, so coalescing applies
  to every sink uniformly.

## Test wiring (test/CMakeLists.txt)

`test_LogCoalescer` built from
`test/engine/System/Log/testLogCoalescer.cpp` via `add_spring_test`, no extra
libs (the System library carries the backend). The test declares the C symbol
`log_backend_record` itself (it is defined in Backend.cpp but only externed in
DefaultFilter.cpp), registers a capture sink, and drives records straight
through the choke point with a `RepeatLimitGuard` RAII restoring the
`log_filter` repeat limit.

## Determinism note

Everything above is in `rts/System/Log/` — outside `rts/Sim/` and
`rts/lib/streflop/`. The coalescer changes what log lines are *written*, not
any game-state computation, so the multiplayer bit-exactness contract is
untouched.
