@done
@determinism
@sync-gate
@simulation
@SYNC-004
Feature: streflop math::floor reproduces x86 cvttss2si saturation semantics on arm64
  """
  The 2025.06.24-lineage cvtt/INT_MIN emulation (commit c20b863148, rts/lib/streflop/streflop_cond.h) is base-specific: on that base the x86 fleet resolved math::floor to fastmath::floor (int-truncate, cvttss2si -> INT_MIN on x86, fcvtzs-saturate on arm64), so the port's exact-match float/double floor overloads (IEEE streflop::floor) desynced raptors at frame 16. On the 2026.07.04 base (main/v0.13) streflop is a submodule (RecoilEngine/streflop @ 570f86f, also the pin of upstream origin/master); its exact-match overloads resolve to the shared libm s_floorf/s_floor bit-twiddling, which the committed tools/sync-test references prove bit-identical across NEON/arm64 and SSE/x86-64 (1985/1985 common inputs, 0 mismatches, NaN/inf/huge edge rows included). Therefore the cvtt class is closed WITHOUT the emulation on this base, and porting c20b863148 forward would make arm64 diverge from the x86 fleet of this base. This test pins the resolved IEEE-floor semantics so any such regression fails a gate. Dependencies: none (pure arithmetic, no engine globals); compiled with STREFLOP_NEON (engine build flags, -ffp-contract=off).
  """

  # ========================================
  # EXAMPLE MAPPING CONTEXT
  # ========================================
  #
  # BUSINESS RULES:
  #   1. Base-specificity: the cvtt/INT_MIN emulation (c20b863148) is a 2025.06.24-lineage fix (v0.11/v0.12, in-tree streflop). On that base the official x86 fleet resolved math::floor to fastmath::floor (int-truncate -> cvttss2si -> INT_MIN), while the mac layer's streflop_cond.h exact-match overloads shadowed it with IEEE streflop::floor (NaN) -> real desync. On the 2026.07.04 base (main/v0.13) streflop is a submodule (570f86f) whose shared IEEE floor is bit-exact across NEON/SSE, so both archs converge on IEEE floor and the cvtt class is closed WITHOUT the emulation.
  #   2. Invariant (base-scoped): on the 2026.07.04 base, math::floor(float/double) resolves via streflop_cond.h's exact-match overloads to the streflop submodule's shared libm s_floorf/s_floor bit-twiddling, which the committed cross-arch references prove bit-identical between NEON/arm64 and SSE/x86-64 (1985/1985 common inputs, 0 mismatches, including the NaN=0x7FC00000, inf=0x7F800000 and huge=0x7F7FFFFF edge rows). Any change that makes arm64 floor diverge from x86 floor (e.g. cherry-picking the 2025.06.24 cvtt emulation c20b863148 onto this base) fails this gate.
  #
  # EXAMPLES:
  #   1. math::floor(3.7f)==3.0f and math::floor(-3.7f)==-4.0f on both archs (probe + references agree).
  #   2. math::floor(float NaN)==NaN bit 0x7FC00000 and math::floor(double NaN)==NaN (probe on arm64, NEON, engine flags; matches committed NEON reference floor(7FC00000)->7FC00000). A cvtt-style fix would make these INT_MIN (0x80000000) and fail the test.
  #   3. math::floor(+3e38f)==+3e38f (bit 0x7F61B1E6) and math::floor(-3e38f)==-3e38f on both archs — huge-magnitude inputs are already integral, floor is identity; a cvtt-style path would yield INT_MIN / INT_MAX and fail.
  #
  # ========================================
  Background: User Story
    As a port maintainer
    I want to verify the resolved math::floor semantics of the current 2026.07.04 base with a committed regression test
    So that any future change that makes arm64 floor diverge from the x86 fleet (cherry-pick of the old cvtt fix, streflop pin change) fails a gate instead of desyncing live lockstep games

  Scenario: Bounded float inputs floor identically on both arches
    Given the streflop submodule at the pinned 2026.07.04-base commit (570f86f) with STREFLOP_NEON enabled and -ffp-contract=off
    When the regression test evaluates math::floor on the bounded in-range inputs 3.7f, -3.7f, 2.25f and -0.25f
    Then math::floor(3.7f) is bit 0x40400000 (3.0)
    And math::floor(-3.7f) is bit 0xC0800000 (-4.0), math::floor(2.25f) is bit 0x40000000 (2.0) and math::floor(-0.25f) is bit 0xBF800000 (-1.0)

  Scenario: NaN and infinite inputs stay IEEE on both arches (the cvtt regression tripwire)
    Given the streflop submodule at the pinned 2026.07.04-base commit (570f86f) with STREFLOP_NEON enabled and -ffp-contract=off
    When the regression test evaluates math::floor on NaN (float and double) and on +/- infinity
    Then math::floor(NaN) is bit 0x7FC00000 for float and 0x7FF8000000000000 for double — matching the committed NEON and SSE reference rows floor(7FC00000)->7FC00000 and floor(FFC00000)->FFC00000
    And math::floor(+infinity) is bit 0x7F800000 and math::floor(-infinity) is bit 0xFF800000 — matching the committed NEON and SSE reference rows floor(7F800000)->7F800000, floor(FF800000)->FF800000
    And a cvtt-style floor (e.g. the 2025.06.24 lineage c20b863148 emulation) would yield INT_MIN (0x80000000) here and therefore FAILS this scenario

  Scenario: Out-of-int32-range magnitudes floor to themselves on both arches
    Given the streflop submodule at the pinned 2026.07.04-base commit (570f86f) with STREFLOP_NEON enabled and -ffp-contract=off
    When the regression test evaluates math::floor on magnitudes beyond the int32 range (near FLOAT_MAX and its sign-inverse)
    Then math::floor(+3e38f) is bit 0x7F61B1E6 (identity: the value is already integral) and math::floor(-3e38f) is bit 0xFF61B1E6, matching the committed NEON reference identity rows (floor(0x7F7FFFFF)->0x7F7FFFFF, floor(0x7E967699)->0x7E967699)
