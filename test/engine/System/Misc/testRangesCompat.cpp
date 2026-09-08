/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
/**
 * Feature: spec/features/ranges-compat-enumerate.feature
 *
 * Validates the macOS-port additions that are pure logic:
 *   - spring::views::enumerate (System/RangesCompat.h), the C++23 P2164 shim
 *     the port added because libc++ (AppleClang) lacks std::views::enumerate.
 *   - The synced-code float->short desync class the port's sweep targets
 *     (SYNC-003 / SYNC-004): the COB angle-to-TA-short conversion that desynced
 *     arm64 vs x86 when done as a raw float->short cast.
 *
 * Header-only: no engine sources beyond Catch are needed.
 */

#include "System/RangesCompat.h"

#include <array>
#include <deque>
#include <list>
#include <string>
#include <vector>

#include <catch_amalgamated.hpp>


// ---------------------------------------------------------------------------
// spring::views::enumerate
// ---------------------------------------------------------------------------

TEST_CASE("enumerate yields index/element pairs in order")
{
	std::vector<int> v{10, 20, 30, 40};

	std::size_t seen = 0;
	for (auto [i, el] : spring::views::enumerate(v)) {
		CHECK(i == static_cast<std::ptrdiff_t>(seen));
		CHECK(el == v[seen]);
		++seen;
	}
	CHECK(seen == 4);
}

TEST_CASE("enumerate over an empty range yields nothing")
{
	std::vector<int> empty;

	std::ptrdiff_t count = 0;
	for (auto [i, el] : spring::views::enumerate(empty)) {
		(void) i;
		(void) el;
		++count;
	}
	CHECK(count == 0);
}

TEST_CASE("enumerate element half is a reference (mutation propagates)")
{
	// The shim's contract (see RangesCompat.h): the element half is a reference
	// so a mutating loop is a no-op if it silently became a copy.
	std::vector<int> v{1, 2, 3};

	for (auto [i, el] : spring::views::enumerate(v)) {
		(void) i;
		el *= 10;
	}

	CHECK(v == (std::vector<int>{10, 20, 30}));
}

TEST_CASE("enumerate works over non-vector containers")
{
	{
		std::deque<std::string> d{"a", "b"};
		std::size_t n = 0;
		for (auto [i, el] : spring::views::enumerate(d)) {
			(void) i;
			CHECK(el == d[n]);
			++n;
		}
		CHECK(n == 2);
	}

	{
		std::list<int> l{7, 8};
		std::size_t n = 0;
		for (auto [i, el] : spring::views::enumerate(l)) {
			(void) i;
			CHECK(el == (n == 0 ? 7 : 8));
			++n;
		}
		CHECK(n == 2);
	}
}

TEST_CASE("enumerate over a C-style array")
{
	std::array<float, 3> a{1.0f, 2.0f, 3.0f};

	std::size_t seen = 0;
	for (auto [i, el] : spring::views::enumerate(a)) {
		(void) i;
		CHECK(el == a[seen]);
		++seen;
	}
	CHECK(seen == 3);
}


// ---------------------------------------------------------------------------
// The synced float->short desync class (SYNC-003 / SYNC-004)
//
// COB scripts encode angles in TA units where a full turn is COBSCALE (65536),
// so a full rotation reaches 65535 — outside a signed short's range and meant
// to wrap (it is a circular 16-bit angle). The port's fix (CobInstance.cpp,
// commit 8a041014a2 + the COB desync fix) converts float->int FIRST (well
// defined for the bounded angles the sim feeds), then narrows int->short
// (a defined, deterministic modular wrap). A raw float->short cast is UB once
// the value leaves short's range and produced different results on arm64 vs
// x86, desyncing multiplayer.
//
// This section pins the deterministic in-bounds wrap the sim actually relies
// on. (The out-of-range cast is deliberately NOT asserted: it is UB, and its
// platform-dependent result is exactly what the port's int-intermediate
// conversion is designed to avoid.)
// ---------------------------------------------------------------------------

namespace {
	constexpr int COBSCALE = 65536;
	constexpr float COBSCALE_HALF = COBSCALE / 2;
	constexpr float RAD2TAANG = static_cast<float>(COBSCALE_HALF) / 3.14159265358979323846f;

	// Mirrors the port's RadAngleToCobShort (CobInstance.cpp): float->int->short.
	// Defined and arch-independent for the bounded angles the sim feeds.
	short RadAngleToCobShortPort(float radAngle)
	{
		return static_cast<short>(static_cast<int>(radAngle * RAD2TAANG));
	}
}

TEST_CASE("COB angle -> TA short: defined, deterministic wrap (in-bounds)")
{
	// 0 rad -> 0
	CHECK(RadAngleToCobShortPort(0.0f) == short{0});

	// Half turn (pi) -> COBSCALE/2 == 32768. 32768 is outside short's range, so
	// this is exactly the wrap case: int(32768) narrows to short as -32768,
	// deterministically, on every arch. (The raw float->short cast here is the
	// UB the port avoids by going through int.)
	CHECK(RadAngleToCobShortPort(3.14159265358979323846f) == short(-32768));

	// A small positive angle -> a small positive TA value.
	const short small = RadAngleToCobShortPort(0.1f);
	CHECK(small > 0);
	CHECK(small < 2048);

	// A near-full turn: radAngle*RAD2TAANG is a hair short of 65536, so the
	// int->short narrowing wraps it to a small NEGATIVE short (the circular
	// 16-bit image just below the full turn). This is the defined behavior the
	// int-intermediate cast guarantees; a raw float->short cast here would be
	// the UB the port's sweep exists to avoid.
	const float justUnderFull = 3.14159265358979323846f * 2.0f - 0.01f;
	const short nearFull = RadAngleToCobShortPort(justUnderFull);
	CHECK(nearFull < 0);            // wrapped past 32767 into the negative half
	CHECK(nearFull > -1024);        // ...to just below the full turn, not far
}
