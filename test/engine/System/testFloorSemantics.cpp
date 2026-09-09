/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
/**
 * Feature: spec/features/streflop-math-floor-reproduces-x86-cvttss2si-saturation-semantics-on-arm64.feature
 *
 * SYNC-004 — regression guard for the resolved math::floor semantics on the
 * 2026.07.04 base.
 *
 * History: on the 2025.06.24 base the x86 fleet resolved math::floor to
 * fastmath::floor (int-truncate; cvttss2si -> INT_MIN on x86,
 * fcvtzs-saturate on arm64). The mac layer's exact-match float/double floor
 * overloads in streflop_cond.h shadowed that with IEEE streflop::floor, so
 * synced Lua math.floor (raptors: floor(0/0)) desynced at frame 16; the fix
 * (c20b863148) emulated the x86 cvtt result (NaN/out-of-range -> INT_MIN).
 *
 * On the 2026.07.04 base (this tree) streflop is a submodule (RecoilEngine/
 * streflop @ 570f86f, also the pin of upstream origin/master's x86 builds)
 * whose exact-match overloads resolve to the shared libm s_floorf/s_floor
 * bit-twiddling — pure integer bit manipulation, arch-independent, and
 * bit-identical between the committed tools/sync-test NEON/arm64 and
 * SSE/x86-64 references (1985/1985 common inputs, 0 mismatches).
 *
 * This test therefore PINS the IEEE-floor result (NaN in -> NaN out, huge
 * magnitudes -> identity), which is what the 2026.07.04 x86 fleet computes.
 * It is the tripwire in both directions:
 *   - a cherry-pick of the 2025.06.24 cvtt emulation (c20b863148) would make
 *     floor(NaN) = INT_MIN on arm64 while the x86 fleet of THIS base returns
 *     NaN -> these checks fail;
 *   - any streflop pin change that makes floor arch-divergent fails here.
 *
 * Include order mirrors rts/lib/lua/src/lmathlib.cpp (the synced Lua
 * math.floor callin): streflop_cond.h first, FastMath.h second, so overload
 * resolution in this test matches the engine's.
 */

#include <cmath>
#include <cstring>
#include <cstdint>
#include "lib/streflop/streflop_cond.h"
#include "System/FastMath.h"

#include <catch_amalgamated.hpp>

// @step Given the streflop submodule at the pinned 2026.07.04-base commit (570f86f) with STREFLOP_NEON enabled and -ffp-contract=off
// This gate exercises the streflop synced path (the engine builds with
// ENABLE_STREFLOP=ON / STREFLOP_AUTO, so STREFLOP_NEON on arm64 or
// STREFLOP_SSE on x86 is defined transitively from the streflop target).
// Without streflop, streflop_cond.h falls back to std::floor and this guard
// no longer validates the synced path — fail loud at compile time.
// Mirrors streflop_cond.h's own STREFLOP_ENABLED test: if no STREFLOP_* mode
// is defined, streflop_cond.h silently falls back to std::floor and this
// guard would validate the wrong path.
#if !defined(STREFLOP_SSE) && !defined(STREFLOP_NEON) && !defined(STREFLOP_X87) && !defined(STREFLOP_SOFT)
#error "testFloorSemantics: this gate must run on the streflop synced path (link the streflop target / ENABLE_STREFLOP=ON)"
#endif
// -ffp-contract=off is baked into the engine's CMAKE_CXX_FLAGS (no fast-math
// or FMA contraction anywhere); nothing to check at runtime, documented here
// so a flag change is reviewed against this file.

namespace {
	uint32_t fbits(float v) { uint32_t b; std::memcpy(&b, &v, 4); return b; }
	uint64_t dbits(double v) { uint64_t b; std::memcpy(&b, &v, 8); return b; }
}

TEST_CASE("FloorSemantics")
{
	// ============================================================
	// Scenario: Bounded float inputs floor identically on both arches
	// ============================================================

	// @step Given the streflop submodule at the pinned 2026.07.04-base commit (570f86f) with STREFLOP_NEON enabled and -ffp-contract=off
	const float boundedInputs[] = { 3.7f, -3.7f, 2.25f, -0.25f };
	(void)boundedInputs; // inputs asserted below; array documents the sweep

	// @step When the regression test evaluates math::floor on the bounded in-range inputs 3.7f, -3.7f, 2.25f and -0.25f
	const float f3_7   = math::floor( 3.7f);
	const float fm3_7  = math::floor(-3.7f);
	const float f2_25  = math::floor( 2.25f);
	const float fm0_25 = math::floor(-0.25f);

	// @step Then math::floor(3.7f) is bit 0x40400000 (3.0)
	CHECK(fbits(f3_7) == 0x40400000u);

	// @step And math::floor(-3.7f) is bit 0xC0800000 (-4.0), math::floor(2.25f) is bit 0x40000000 (2.0) and math::floor(-0.25f) is bit 0xBF800000 (-1.0)
	CHECK(fbits(fm3_7)  == 0xC0800000u); // -4.0
	CHECK(fbits(f2_25)  == 0x40000000u); //  2.0
	CHECK(fbits(fm0_25) == 0xBF800000u); // -1.0

	// ============================================================
	// Scenario: NaN and infinite inputs stay IEEE on both arches
	// (the cvtt regression tripwire)
	// ============================================================

	// @step Given the streflop submodule at the pinned 2026.07.04-base commit (570f86f) with STREFLOP_NEON enabled and -ffp-contract=off
	const float nanf = 0.0f / 0.0f; // quiet NaN, 0x7FC00000
	const double nand = 0.0 / 0.0;  // quiet NaN, 0x7FF8000000000000
	const float pinf = 1.0f / 0.0f;
	const float ninf = -1.0f / 0.0f;

	// @step When the regression test evaluates math::floor on NaN (float and double) and on +/- infinity
	const float  fNaN  = math::floor(nanf);
	const double dNaN  = math::floor(nand);
	const float  fPInf = math::floor(pinf);
	const float  fNInf = math::floor(ninf);

	// @step Then math::floor(NaN) is bit 0x7FC00000 for float and 0x7FF8000000000000 for double — matching the committed NEON and SSE reference rows floor(7FC00000)->7FC00000 and floor(FFC00000)->FFC00000
	CHECK(fbits(fNaN) == 0x7FC00000u);
	CHECK(dbits(dNaN) == 0x7FF8000000000000ull);

	// @step And math::floor(+infinity) is bit 0x7F800000 and math::floor(-infinity) is bit 0xFF800000 — matching the committed NEON and SSE reference rows floor(7F800000)->7F800000, floor(FF800000)->FF800000
	CHECK(fbits(fPInf) == 0x7F800000u);
	CHECK(fbits(fNInf) == 0xFF800000u);

	// @step And a cvtt-style floor (e.g. the 2025.06.24 lineage c20b863148 emulation) would yield INT_MIN (0x80000000) here and therefore FAILS this scenario
	// Negative guard: the cvtt/INT_MIN result must NOT appear on this base.
	// If c20b863148's x86_cvtt_i32 emulation is cherry-picked onto the
	// 2026.07.04 base, math::floor(NaN) becomes INT_MIN: 0x80000000 for
	// float, and the finite value -2147483648.0 for double -> gate red.
	CHECK(fbits(fNaN) != 0x80000000u);
	CHECK(std::isnan(dNaN)); // cvtt would hand back a finite INT_MIN double

	// ============================================================
	// Scenario: Out-of-int32-range magnitudes floor to themselves
	// on both arches
	// ============================================================

	// @step Given the streflop submodule at the pinned 2026.07.04-base commit (570f86f) with STREFLOP_NEON enabled and -ffp-contract=off
	// 3e38 is far beyond int32 range; as a float it already has no
	// representable fractional part (exponent >= 2^23 region), so IEEE
	// floor is identity — exactly what the committed NEON reference rows
	// record (floor(0x7F7FFFFF)->0x7F7FFFFF, floor(0x7E967699)->0x7E967699).
	const float bigpos = 3e38f;
	const float bigneg = -3e38f;

	// @step When the regression test evaluates math::floor on magnitudes beyond the int32 range (near FLOAT_MAX and its sign-inverse)
	const float fBigPos = math::floor(bigpos);
	const float fBigNeg = math::floor(bigneg);

	// @step Then math::floor(+3e38f) is bit 0x7F61B1E6 (identity: the value is already integral) and math::floor(-3e38f) is bit 0xFF61B1E6, matching the committed NEON reference identity rows (floor(0x7F7FFFFF)->0x7F7FFFFF, floor(0x7E967699)->0x7E967699)
	CHECK(fbits(fBigPos) == 0x7F61B1E6u);
	CHECK(fbits(fBigNeg) == 0xFF61B1E6u);
	// Identity, not saturation: a cvtt-style path would yield INT_MIN /
	// INT_MAX (0x80000000 / 0x7FFFFFFF) here — the gate must catch that.
	CHECK(fbits(fBigPos) != 0x7FFFFFFFu);
	CHECK(fbits(fBigNeg) != 0x80000000u);
}
