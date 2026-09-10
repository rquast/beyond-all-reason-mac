# Upstream candidates from the Phase C perf campaign (2026-07-11)

Everything below was found while taking BAR from 6.8 → 32+ fps (heavy cells)
on zink→KosmicKrisp→Metal, with identical rendering. Ordered by expected
upstream value.

## Upstream status at the Mesa 26.2.2 pin (2026-09-10)

- **Landed upstream, our local patch dropped** — `zink: Address
  libvulkan.1.dylib dlopen failure on macOS` (upstream `c26d3301b26`, in 26.2.2):
  zink now dlopens `@rpath/libvulkan.1.dylib` and the build bakes the loader
  location via the new `-Dvulkan-loader-rpath` meson option (our build script
  passes `/opt/homebrew/lib` for dev runs; the release bundle resolves it via
  the engine's LC_RPATH). Our old `patches/mesa/0009` (try @rpath before bare
  name) was redundant and was removed.
- **Landed upstream, our local patch dropped** — `kk: Compile all shaders with
  fast math` (upstream `bdc3a6afe1a`, in 26.2.2): KosmicKrisp now compiles
  every shader with `MTLMathModeFast` natively (with per-ALU math controls via
  `VK_KHR_shader_float_controls2`). Our old `patches/mesa/0012`
  (`KK_MATH_MODE` knob) was redundant and was removed; the engine's
  `setenv("KK_MATH_MODE", "fast")` is now inert (kept only as a user override
  for older driver builds).
- **Landed on `main` (95c504fa17a) but NOT in the 26.2.2 stable branch —
  still carried locally** — zink renderpass tracking for KosmicKrisp (our old
  patch 0013, now `patches/mesa/0009`; the +4.8% M2-Air win). Re-dropped once
  it backports to stable 26.2.x.
- **Still not upstreamed — still carried locally** (patch numbers at the
  26.2.2 pin): 0001 poly scratch barrier (old 0001), 0002 push-desc
  save/restore (old 0002), 0003 fillModeNonSolid (old 0008), 0004 geometry
  heap reset-once (old 0003), 0005 zero-init device memory (old 0006), 0006
  dylib-load log (old 0007), 0007 vertex_buffers_dirty consume-on-bind (old
  0010; the consume-site moved from zink_draw.cpp to
  zink_context.c::zink_bind_vertex_buffers_internal in 26.2.2), 0008
  vertex-elements pipeline gate (old 0011), 0009 renderpass tracking for
  KosmicKrisp (old 0013, above).

Note: the 26.2.2 Metal4 rework (`kk: Move to Metal4 command encoding`,
`kk: Record command buffers live and replay only on resubmit`) deleted the
per-queue pre_gfx command-queue that our old patch 0005 (cross-submission
heap ordering) ordered events on — the queue is now a single Metal command
queue with one command buffer per submission, so that hazard is
unrepresentable and the patch was dropped. It also turned
`kk_cmd_write` from a deferred `encoder->imm_writes` list into an IMMEDIATE
`libkk_write_u32` dispatch into the pre_gfx encoder (when not mid-render),
with a `DISPATCH->DISPATCH` barrier after every libkk dispatch
(`kk_cmd_meta.c`) — which is exactly the ordering the second hunk of our old
geometry-heap patch (now 0004) was hand-encoding, so that hunk is
superseded by upstream and only the `uses_heap` hunk survives (now 0004).
Old patch 0004 (uploader bump-state
clear) is redundant because the 26.2.2 reset path already nulls
`cmd->uploader.bo/offset`.

## 1. Recoil engine PR: LuaVAO — enable GL_PRIMITIVE_RESTART only for strip/loop/fan modes
`engine-2025.06.24@65a1749c29` / `engine@f40af7ce50`.
LuaVAOImpl force-enables restart around every draw (incl. `Submit()` which is
hardcoded GL_TRIANGLES MDI) with restart index `0xffffff` for 32-bit buffers
(Lua 2^24 limit). On any Metal-backed GL stack this forces a per-draw compute
index-unroll (Metal only has fixed all-ones restart): 94% of BAR's draws paid
it → 6.8 fps. Restart is meaningless for list topologies unless the index
stream contains sentinels, which engine-fed meshes never do. Escape hatch:
`SPRING_LUAVAO_FORCE_RESTART=1`. Helps zink/ANGLE/Metal ports; no-op on
native desktop drivers.

## 2. Recoil engine PR: IStreamBuffer WaitBuffer — don't spin glClientWaitSync at 1ns
`WaitBuffer()` loops `glClientWaitSync(..., 1)` — thousands of driver
round-trips per frame when the fence isn't signaled. 250µs blocking waits are
semantically identical. Also: PERSISTENT_MAPPING_BUFFERING=3 assumes ≤2
frames of GPU completion latency; translation stacks (zink/KK) run deeper —
made configurable/6 on macOS.

## 3. KosmicKrisp: primitiveTopologyListRestart honesty vs cost
KK advertises `primitiveTopologyListRestart`, and honors it via a full
compute unroll + cross-queue pre_gfx ping-pong per draw batch. For apps that
"technically against spec" leave restart enabled on list draws (the code
comment already anticipates them), this is a 10-100× draw-cost cliff.
Consider: not advertising the feature (zink then filters restart on lists
itself), or a device-level opt-out. Data: BAR m7 arena 6.8→23.1 fps from
eliminating these unrolls.

## 4. Mesa st/readpixels + zink: GPU-pack path gaps (present-readback cliff)
- `st_ReadPixels`' "format matches → cheap memcpy fallback" maps a TILED
  resource on zink → staging blit queued behind the whole frame (~30ms in
  heavy scenes). The GPU-pack PBO path avoids it entirely but requires
  (a) a bound PIXEL_PACK buffer and (b) a non-swizzling format pair —
  BGRA read of RGBA8 fails `try_pbo_readpixels` (storage-image write in
  b8g8r8a8?) and silently falls back. Diagnosable only with driver prints
  (our `ST_DEBUG_READPIX`). A perf warning or a swizzle-capable pack shader
  would help every zink-on-Metal/portability consumer.
- zink: `ZINK_NO_TRIANGLE_FANS` env (our patch) — lets zink convert fans
  even when the driver claims support; useful when driver-side conversion
  is disproportionately expensive (KK compute unroll).

## 5. CAMetalLayer nextDrawable pacing (documentation/sample-code worthy)
Calling `nextDrawable` on the render thread paced an under-refresh workload
to exactly refresh/2 (60 on a 120Hz panel), blocking ~12ms/frame;
`maximumDrawableCount=3` did not change it. Moving present to a serial
dispatch queue with a budget-2 semaphore + double-buffered IOSurface source
restored full-rate presentation. Pattern likely affects any GL-translation
present path that reads back and re-presents.

## Added 2026-07-11 (review-hardening pass)

### 6. Recoil engine PR: float→short / float→int UB fixes in synced code
`engine-2025.06.24@39be48f839` (COB callins; found by live desync clang-arm64
vs gcc-x86) + the audit sweep of the same class (IPathController,
Ground/HoverAirMoveType direct-control heading, LuaSyncedMoveCtrl.SetHeading,
LuaSyncedRead.GetFacingFromHeading). Out-of-range float→short is UB; the two
fleet compilers disagree. Defined int32 truncation, gcc-x86-identical.
Full register: engine SYNC_VALIDATION.md Appendix A.

### 7. Recoil engine PR: streflop math::floor — x86 cvttss2si semantics on arm64
`engine-2025.06.24@4a01bf411f` (cherry-picked here as `c20b863148`).
Out-of-range float→int is UB; x86 saturates to 0x80000000 and game code
observes it (raptors desync). Emulate on arm64.
**Base-scoped to the 2025.06.24 lineage (v0.11/v0.12, in-tree streflop).**
On the 2026.07.04 base (main/v0.13) streflop is a submodule
(`RecoilEngine/streflop @ 570f86f`, also upstream master's x86 pin) whose
`math::floor` resolves on both arches to the shared libm `s_floorf`/
`s_floor` bit-twiddling — bit-identical NEON vs SSE per the committed
`tools/sync-test` references. The cvtt class is closed without the
emulation on this base, and cherry-picking this PR forward would make
arm64 diverge from this base's x86 fleet. Pinned by
`test_FloorSemantics` (SYNC-004); see SYNC_VALIDATION Appendix A.

### 8. Recoil engine PR: SDL_AUDIODEVICEADDED passes a device index, not an instance id
`fd63d525d8` subset. The handler compared an index against instance ids and
tore down a working device on hot-plug ADDED events (macOS device-churn crash
storm). Platform-independent bug.

### 9. Recoil engine PR: don't terminate on joinable ext threads at fatal-path exit
`fd63d525d8` subset. ExitSpringProcess calls exit() off-main, bypassing
ClearExtJobs; static destruction of a joinable std::thread is terminate().
Detach leftovers in the container's destructor; guard the join.

### 10. Recoil engine PR: configurable WindowTitle ({version} placeholder)
`816e1cbf3d`. Lets a game distribution brand the window without forking the
engine; default title unchanged.
