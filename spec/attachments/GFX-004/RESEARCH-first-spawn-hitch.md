# GFX-004 Research: per-unit first-spawn hitch on the macOS port

Date: 2026-09-11 · Researcher: AI agent (Claude) with human review required (AI_POLICY.md)

## 0. Implementation status (2026-09-11)

Option A implemented and unit-tested. Final design:

- **`S3DModel::NeedsFirstUpload()`** — new *inline* predicate in
  `rts/Rendering/Models/3DModel.hpp` (kept inline + GL-free so the selection
  policy is unit-testable; `myGL.h` `#error`s under `UNIT_TEST`, so the
  GL-bound `3DModel.cpp`/`IModelParser.cpp` translation units cannot link into
  a headless test). Returns true only for `LOADED` + !`uploaded` +
  non-`MODELTYPE_3DO` models.
- **`CModelLoader::UploadAllLoaded()`** — new method
  (`rts/Rendering/Models/IModelParser.{h,cpp}`): iterates the model pool, calls
  the existing per-model `Upload()` for every `NeedsFirstUpload()` model.
  Reuses all existing bookkeeping (`model->uploaded`, shatter-index release,
  normal check) — first-use thereafter is a no-op.
- **Call site** — `CWorldDrawer::InitPost()`
  (`rts/Rendering/WorldDrawer.cpp`), inside the existing `CLoadLock`
  (recursive; per-model `Upload()` re-locks safely), immediately after
  `mv.UploadVBOs()` and only when `PreloadModels=1`.
- **Enabler** — `rts/Rendering/Common/UpdateList.cpp` was missing
  `#include <cassert>` (latent: only compiled in-tree because another header
  provided it transitively); added.
- **Test** — `test/engine/Rendering/testModelNeedsFirstUpload.cpp` (Catch2,
  registered as `test_ModelNeedsFirstUpload` in `test/CMakeLists.txt`):
  constructs `S3DModel` instances in place (no moves → no GL-bound move-ctor
  needed; `traAlloc` 0-elem path early-returns in the dtor) and verifies the
  selection policy mirrors the `UploadAllLoaded()` loop. Links only
  `ModelsMemStorage.cpp` + `UpdateList.cpp` + the threading set, plus a
  link-only `Transform::Zero()` stub (referenced by the inlined
  `ScopedTransformMemAlloc` dtor, never executed).
- **Red/Green evidence** — with the predicate temporarily forced to
  `return true`, the test fails (`4 == 3`, selected count includes the 3DO
  model); restored, all 12 assertions pass. Full ctest suite: 30/33 pass; the
  3 failures are pre-existing environment issues (testCreg/testUnitSync need
  the `base/springcontent.sdz` game asset; testUDPListener auto-skips) and are
  unrelated to this change.
- **Not headless-testable (manual verification required)**: the GL orchestration
  (`UploadAllLoaded → Upload → LoadTexture → glTexImage2D/glGenerateMipmap`),
  the load-time behavior in a real game, and the absence of `[stall] draw gap`
  lines on first spawns. Procedure: run a game (e.g. via the packaged app),
  force first spawns of several unit types, grep the infolog for
  `[stall] draw gap` (the stall logger at
  `rts/Rendering/GlobalRendering.cpp:803`), and compare load-time delta.
  Tracy build: confirm no `Upload`/`LoadTexture`/`glGenerateMipmap` spans on
  the main thread at first spawn.
- **Determinism**: no synced code touched; `NeedsFirstUpload`/`UploadAllLoaded`
  are rendering-side only. Sync-validation gate unaffected (nothing under
  `rts/Sim/` or `rts/lib/streflop/` changed).

---

## 1. Symptom

When a unit/building type first comes into scope (first spawn, first enemy
unit, first structure of a new type), the game pauses briefly. On Windows the
pause is a few milliseconds and invisible; on this macOS port the pause is
clearly visible. The pause happens per *unit type*, not per unit instance:
once a type has spawned, subsequent instances of that type do not pause.

## 2. What the engine already preloads (and what it defers)

All paths verified in this tree (2026.07.04 base + macOS layer) and against
upstream Recoil (`beyond-all-reason/RecoilEngine`, shallow clone in
`/tmp/recoil-upstream`) — the mechanism is identical to upstream, this is not
a port regression.

### At map load (`PreloadModels=1`, the default)

`CWorldDrawer::InitPost()` — `rts/Rendering/WorldDrawer.cpp:80-170`:

1. `CONFIG(bool, PreloadModels)` (line 55, default true).
2. For every unit/feature/weapon def: `def.PreloadModel()` →
   `SolidObjectDef::PreloadModel()` (`rts/Sim/Objects/SolidObjectDef.cpp:66`)
   → `modelLoader.PreloadModel(name)` (`rts/Rendering/Models/IModelParser.cpp:235`),
   which enqueues `modelLoader.LoadModel(name, /*preload=*/true)` on the
   thread pool.
3. `LoadModel(name, preload=true)` (`IModelParser.cpp:280`): parse the S3O
   file, build vertices/indices, then **stops before `Upload()`**
   (line 312: `if (!preload) Upload(model);`).
4. While the S3O parses, the parser calls
   `textureHandlerS3O.PreloadTexture(model, ...)`
   (`rts/Rendering/Models/S3OParser.cpp:70`, also `GLTFParser.cpp:435`,
   `AssParser.cpp:597`) → `CS3OTextureHandler::LoadAndCacheTexture(...,
   /*preloadCall=*/true)` (`S3OTextureHandler.cpp:125`): **decodes the image
   into a CPU `CBitmap` and caches it** (`bitmapCache`), but returns `texID=0`
   — no GL texture object is created.
5. End of load: `DrainPreloadFutures(0)` (waits for all parse futures),
   `S3DModelVAO::UploadVBOs()` (bulk-upload all vertex/index data), then
   `CModelsLock::SetThreadSafety(false)` because "all models are already
   preloaded" (`WorldDrawer.cpp:167`).

**So after load: all geometry is on the GPU, all texture *bitmaps* are
decoded in RAM, and zero S3O GL texture objects exist yet.**

### At first use (the deferred work — the hitch)

`SolidObjectDef::LoadModel()` (`SolidObjectDef.cpp:77`) calls
`modelLoader.LoadModel(modelName)` with `preload=false`, which runs
`Upload(model)` (`IModelParser.cpp:462`):

- `S3DModelVAO::GetInstance().UploadVBOs()` — no-op, already done at load.
- **`textureHandlerS3O.LoadTexture(model)`** (line 476) →
  `LoadAndCacheTexture(..., preloadCall=false)` →
  `bitmap->CreateMipMapTexture()` (`Bitmap.cpp:1857`) →
  `CreateTexture()` (`Bitmap.cpp:1722`) →
  `RecoilBuildMipmaps()` (`myGL.cpp:404`):
  - `glTexImage2D` of the base level (CPU → GPU upload),
  - `glTexImage2D` with `data=nullptr` for every other level (empty level
    reservation),
  - **`glGenerateMipmap`** (line 428) — GPU-side mipmap generation.

This runs **synchronously on the main thread**, under `CLoadLock::GetUniqueLock()`,
the first time that def's model is loaded non-preloaded.

Triggers observed in this tree:

- `CUnit::PreInit` — `rts/Sim/Units/Unit.cpp:233`
  (`unitDef->LoadModel()` at spawn; also `:212` for wreck feature defs,
  `:221` for build-options preloading of *future* build products, which is a
  partial mitigation: a buildable unit type gets its upload at build-start,
  not first draw).
- First-draw paths: `UnitDrawer.cpp:896,1313,1346,1532,1578,1826`
  (`unitDef->LoadModel()` / `decoyDef->LoadModel()`),
  `UnitDrawerData.cpp:128` (ghost objects: `modelLoader.LoadModel`),
  `FeatureDrawer.cpp` model-renderer paths,
  `ModelsDataUploader.cpp:239,249` (transform SSBO slot allocation for
  ghost/def objects).

So enemy units, map features, decoys, wrecks and anything not in your
build chain all pay the full upload at *first draw* — matching the reported
"pause when units come into scope."

### Second deferred cost: shader variants

`Shader::GLSLProgramObject::Reload(...)` (`rts/Rendering/Shaders/Shader.cpp:
~633-701`): on a cache miss (`UseShaderCache` LRU), it runs
`glCreateProgram` + `CompileShaderObject` (per-stage `glCompileShader`,
line 203) + `glLinkProgram` (line 675). Unit/feature shader flags depend on
per-object state (glow, alpha, PBR variants...), so the *first frame a
variant is used* compiles+links it on the main thread. This is a second,
independent source of the same "new unit appears → hitch" symptom.

## 3. Why it costs far more on this Mac

All of the deferred work is the same on Windows, but each step is
disproportionately expensive through GL 4.6 → Zink → KosmicKrisp → Metal:

### 3.1 Texture upload + glGenerateMipmap

Verified against current Mesa main (clone in `/tmp/mesa-zink`,
`src/gallium/drivers/zink/`, `src/mesa/state_tracker/`):

- **Mesa state tracker** (`src/mesa/state_tracker/st_gen_mipmap.c:144`):
  `glGenerateMipmap` uses the driver's `pipe->generate_mipmap` if advertised;
  otherwise `util_gen_mipmap` (CPU blit chain — a full-screen 2D render
  pass per level, through *this* driver, i.e. N extra
  renderpasses/submits), else a pure-CPU software fallback. Zink does not
  advertise native `generate_mipmap` (not in `zink_screen.c` caps), so
  mipmap generation here is a chain of GPU blit passes, not a free native
  fast-path like on a native desktop driver.
- **Zink blits** (`zink_blit.c:380` `zink_blit`): each blit may force
  `zink_batch_no_rp_safe` (renderpass close), insert image-layout barriers
  (`zink_blit_barriers`), and — critically — if the source buffer object is
  device-resident (`src->obj->dt`, line 458) it calls
  `zink_kopper_acquire_readback`, which is a **synchronous GPU→CPU
  readback fence wait** on the calling (main) thread. On a translation
  stack where the GPU legitimately runs 2-3 frames deep (see
  `docs/PERF_REVIEW.md` §4), that wait is the whole pipeline draining.
- **Uploads**: `glBufferSubData`/`glTexImage2D` data goes through zink's
  transfer path (`zink_resource.c:2825` `transfer_get_map`): for
  non-linear (image) resources with non-host-visible storage it allocates a
  staging buffer and issues a copy; writes with existing GPU usage trigger
  `zink_fence_wait` (line 2903). Every first-use texture is at least:
  buffer upload + level reservation + blit chain + fence(s).
- Net: on a native driver the whole "first use of a texture" is a near-async
  copy the GPU swallows between frames; here it is several synchronous
  driver round-trips on the main thread, each gated by the deep GPU queue.

### 3.2 Shader compile/link

- Engine side: `glCompileShader`/`glLinkProgram` → zink compiles GLSL→NIR→SPIR-V
  and, on first use of a pipeline state, creates the Metal pipeline
  (KosmicKrisp: NIR→MSL + Apple's MSL compiler). First-use pipeline creation
  in a Vulkan-on-Metal driver is the canonical cause of 10-100ms+ hitches
  (cf. the pipeline-variant discussion in the KosmicKrisp workarounds docs
  and the 2026-05 mesa-dev thread on per-topology pipeline variants).
- Zink does have *asynchronous* program compilation
  (`zink_program.c`: `cache_get_thread` worker, `zink_gfx_program_compile_queue`,
  `util_queue_add_job(... gfx_program_precompile_job)`), but it only kicks in
  for programs zink *precompiles*; the engine's on-demand
  create/compile/link of a new variant still blocks the GL thread until the
  job's fence signals (`util_queue_fence_wait(&pg->cache_fence)`,
  `zink_program.c:1835`).
- Engine mitigations already present: `UseShaderCache` LRU
  (`Shader.cpp:639`), and the 3DO/legacy paths pre-link common variants at
  start. What is missing is *prewarming the variants that unit/feature
  drawing will use*.

### 3.3 Present-path backpressure amplifies one-off stalls

`docs/PERF_REVIEW.md` §6 + `MetalPresent.mm`/`MacPresentBackend.mm`: the
direct-present path fences slot reuse, and "that fence doubles as pipeline
backpressure." When a one-off 50-200ms upload lands, the GPU queue drains
deeper than the ring's steady-state depth; subsequent frames then pay
fence-wait on the main thread, stretching the *visible* pause beyond the
upload itself. The existing stall logger
(`rts/Rendering/GlobalRendering.cpp:803-821`, `[stall] draw gap` > 150ms
warning, disable with `SPRING_NO_STALL_LOG=1`) captures exactly these gaps.

### 3.4 Windows comparison

On Windows (native GL driver, D3D/GL backend with async copies and driver
pipeline caches), the same deferred steps:

- texture upload: async, GPU absorbs it;
- glGenerateMipmap: native fast path;
- shader compile: driver-side pipeline cache usually warm after the first
  few seconds;
- no deep-queue backpressure.

Hence "a few ms, invisible" on Windows vs. a visible pause here. **The
port's steady-state work is fine (the 8x campaign in PERF_REVIEW.md); the
problem is purely that one-off first-use work lands on the main thread in a
stack where one-off work is 10-100x more expensive than on desktop GL.**

## 4. Upstream status

- `spring/spring` (archived 2024-03 base, `/tmp/spring-upstream`): same
  deferral shape (`LoadCachedModel` → `UploadRenderData` on first
  non-preload `LoadModel`), plus `PreloadModels` was **added** by upstream
  Recoil (not in spring) — confirmed present in Recoil upstream
  (`/tmp/recoil-upstream`, same `WorldDrawer.cpp` lines 56/86).
- No upstream issue found that addresses the first-use texture upload hitch;
  the `PreloadModels=0` changelog note (spring 105.1544) is the only
  community-facing mention.
- The fix is therefore a local (macOS-layer) change, candidate for upstream
  later if it measures neutral on desktop (it should be: it only moves
  existing load-time work earlier, and the `uploaded` flag makes
  first-use a no-op).

## 5. Fix options (rendering-only — sim untouched, determinism safe)

**Option A (recommended): complete the deferred GL texture upload at end of
map load.**

In `CWorldDrawer::InitPost()`, after `DrainPreloadFutures(0)` and the bulk
`UploadVBOs()` (line 158-164), iterate the preloaded models and call
`textureHandlerS3O.LoadTexture(model)` for each non-3DO model (or route
through `modelLoader.Upload(model)` for the `uploaded` bookkeeping +
shatter-index release + normal check in one). Cost: longer load screen (the
bitmaps are already decoded — this is pure GL upload + blit-mipmap chain),
hitch moves from "first spawn, mid-game, main thread, under load" to
"load screen, idle scene, main thread."

- Touches: `WorldDrawer.cpp` (+ possibly `IModelParser.h` to expose a
  bulk-upload helper; `CModelLoader` already has `Upload` as a public
  method via `LoadModel(name,false)` — but that re-enters the loader, so a
  dedicated `CModelLoader::UploadAllPreloaded()` is cleaner).
- Risks: load time increases on all platforms; 3DO models unaffected
  (atlas-based, already preloaded); models added at runtime (projectiles
  with late-bound models, Lua `CreateProjectile` visuals) still pay first
  use — acceptable, or prewarm the projectile defs too (they're already
  preloaded via weapon defs in `InitPost`).
- Verify: load time delta, `[stall]` lines in infolog during a standard
  spawn scenario, and the existing sync-validation gate (nothing synced
  touched).

**Option B: prewarm shader variants.** After load (or during load), force
each unit/feature shader flag-combination through `glLinkProgram` once.
Larger change: need to enumerate the flag sets used by
`ModelDrawer`/`UnitDrawer` at draw time; the `UseShaderCache` LRU already
keeps them resident once compiled. This addresses the *second* hitch source
and can be a follow-up card if Tracy shows link stalls after Option A.

**Option C (not recommended): per-frame upload budgeting** — trickle the
uploads across N frames to spread the cost. Keeps load fast but leaves a
tail of hitches, adds state to the drawer, and risks visible "late" textures
(silhouettes first, detail a second later). Rejected unless Option A
makes load unacceptably slow.

**Option D (driver-side, longer-term):** patch zink/KosmicKrisp to make
`transfer_get_map`-style write paths and `util_gen_mipmap` blit chains
non-blocking (async staging + timeline semaphores). This is upstream Mesa
work; tracked under the zero-copy roadmap in `IMPROVEMENTS.md` instead.

## 6. Measurement / verification plan

1. **Reproduce & quantify** (before):
   - Play a standard map; force first spawns of several unit types (or a
     scripted replay).
   - Infolog: count `[stall] draw gap` lines >150ms and their timestamps.
   - Tracy: confirm the stall spans are `Upload` → `LoadTexture` →
     `glGenerateMipmap` (texture) and/or `glLinkProgram` (shader) on the
     main thread; record per-type cost in ms.
2. **After Option A**:
   - Same scenario: no `[stall]` lines from first spawns; load time delta
     recorded (target: acceptable on M2-class hardware; it is load-screen
     work, and `SetLoadMessage` updates exist to show progress).
   - No visual regression: screenshot compare of a fixed scene (unit
     textures must be pixel-identical — the upload code path is unchanged,
     only its timing).
   - Run the sync-validation gate unchanged (no synced code touched).
3. **Regression guard**: `PreloadModels=0` must still work (the deferred
   path stays correct for whatever wasn't uploaded at load).

## 7. Sources

- This tree: files cited above (WorldDrawer.cpp, IModelParser.cpp/h,
  S3OTextureHandler.cpp/h, SolidObjectDef.cpp, Unit.cpp, UnitDrawer.cpp,
  UnitDrawerData.cpp, FeatureDrawer.cpp, ModelsDataUploader.cpp,
  Bitmap.cpp, myGL.cpp, 3DModelVAO.cpp, VBO.cpp, Shader.cpp,
  GlobalRendering.cpp, MetalPresent.mm, MacPresentBackend.mm).
- Port docs: `docs/PERF_REVIEW.md` (§4 deep upload rings, §6 present
  backpressure), `docs/IMPROVEMENTS.md` (stall logger, roadmap),
  `docs/LESSONS.md`, `docs/SYNC_VALIDATION.md`.
- Mesa main (cloned `/tmp/mesa-zink`): `st_gen_mipmap.c`, `zink_blit.c`,
  `zink_resource.c`, `zink_fence.c`, `zink_program.c` (async compile
  queue + `cache_fence`), `zink_screen.c` (caps — no native
  `generate_mipmap`).
- Upstream Recoil (cloned `/tmp/recoil-upstream`) and Spring (archived,
  cloned `/tmp/spring-upstream`): mechanism identical.
- Web: Khronos `glGenerateMipmap` spec; Mesa zink/kosmickrisp driver docs;
  LunarG KosmicKrisp announcement + workarounds doc; mesa-dev 2026-05
  "KosmicKrisp: pipeline-variants-per-topology-class" thread (per-variant
  pipeline creation cost); Vulkan pipeline-cache guide.

## 8. Open questions (red cards)

- @human: is a ~N second increase in load time acceptable to the target
  audience, or do we need Option C-style spreading only on macOS?
- @human: should the fix be macOS-gated (env/config) or unconditional
  (upstreamable)? Unconditional is better for upstream; measure desktop
  load-time delta before deciding.
- After Option A: does Tracy show remaining `glLinkProgram` stalls on first
  unit-type draw? If yes, open a follow-up card for shader prewarming
  (Option B).
