# Pinned versions (BAR macOS port)

| Component | Pin | Why |
|---|---|---|
| Engine (shipping) | branch `macos-2025.06.24` = upstream release tag `2025.06.24` + macOS layer | Matches the BAR public-server engine version; sync gates green (streflop sync-test bit-exact, replay determinism REPLAY_SYNC_OK) |
| Mesa driver | `3281a69a8bfd9f997e91c15ed0e6290cae12dd32` = tag `mesa-26.2.2` (stable 26.2.2 point release, 2026-09-02) + the 9 `patches/mesa/*.patch` | The Zink + KosmicKrisp stack the bundle ships; built from pinned upstream source. Up from `8f272b1fe18` (26.2.0-devel): takes in upstream macOS loader fix (`zink: Address libvulkan.1.dylib dlopen failure` — now via the `-Dvulkan-loader-rpath` meson option, so our old patch 0009 is dropped), KosmicKrisp native fast-math (`kk: Compile all shaders with fast math` — makes our old patch 0012's `KK_MATH_MODE` knob redundant; it is dropped and the engine's `setenv("KK_MATH_MODE", "fast")` is now inert), plus 26.2.x bugfixes (icd json api version, timestamp stage translation, host-imported buffer offsets, swap-interval). Dropped as now-obsolete on 26.2.2: old 0004 (uploader bump-state — upstream reset path already nulls it), old 0005 (pre_gfx ordering — 26.2.2's single Metal queue / one-command-buffer-per-submit makes the old dual-queue hazard unrepresentable). Kept: 0001, 0002, 0003, 0006–0009. |
| SPIRV-LLVM-Translator | `v19.1.7` | Matched to brew llvm@19 for Mesa CLC step |
| LLVM (Mesa build only) | brew `llvm@19` | brew LLVM 22 can't link Mesa's KosmicKrisp CLC step |
| OpenAL | brew `openal-soft` | Apple OpenAL.framework lacks alext/efx |
| pr-downloader | ExaDev fork submodule (e6510b3d) | macOS HTTP/1.1 fix for BAR CDN |
| macOS floor | 26.0 (Tahoe) | KosmicKrisp requires Metal 4 |
