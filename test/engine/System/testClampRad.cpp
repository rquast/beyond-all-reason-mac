/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
/**
 * Feature: spec/features/synced-code-float-short-ub-sweep-matches-fleet-gcc-x86-behavior.feature
 *
 * Validates the synced-code float→short UB sweep (SYNC-003): the TA-short
 * expectations must match the fleet's gcc-x86 behavior (float→int32→short,
 * i.e. cvttss2si-then-narrow). The out-of-range raw float→short cast the
 * gate used before this fix is UB and produced platform-dependent results
 * on arm64 (-O2: fcvtzs saturation → 65535 instead of -1).
 */

#include <cmath>
#include <numeric>
#include "System/SpringMath.h"
#include "System/Misc/SpringTime.h"
#include "Sim/Units/Scripts/CobInstance.h"

#include <catch_amalgamated.hpp>

InitSpringTime ist;

TEST_CASE("ClampRad")
{
	// Test 0 (should return 0)
	CHECK(ClampRad(0.0f) == 0.0f);

	// Test math::TWOPI (should return 0 because TWOPI wraps to 0)
	CHECK(ClampRad(math::TWOPI) == 0.0f);

	// Test std::nextafterf(math::TWOPI, -inf) (should return value just under TWOPI)
	CHECK(ClampRad(std::nextafterf(math::TWOPI, -std::numeric_limits<float>::infinity())) == std::nextafterf(math::TWOPI, -std::numeric_limits<float>::infinity()));

	// Test math::PI (should return PI because PI is in [0, TWOPI))
	CHECK(ClampRad(math::PI) == math::PI);

	// Test negative value -math::PI (should return PI because -PI + TWOPI = PI)
	CHECK(ClampRad(-math::PI) == math::PI);

	// Test negative value -math::TWOPI (should return 0)
	CHECK(ClampRad(-math::TWOPI) == 0.0f);

	// Test std::nextafterf(-math::TWOPI, +inf) (should return small positive value)
	{
		const float input = std::nextafterf(-math::TWOPI, +std::numeric_limits<float>::infinity());
		CHECK(ClampRad(input) == input + math::TWOPI);
	}

	// Test with -0.0f and verify the result is not negative zero (signbit returns false)
	CHECK_FALSE(std::signbit(ClampRad(-0.0f)));

	// Test with +0.0f and verify the result is not negative zero (signbit returns false)
	CHECK_FALSE(std::signbit(ClampRad(0.0f)));

	// Test TAANG2RAD conversion to short for [0, 2pi)
	// The float->int->short form mirrors the engine's synced-code sweep (see
	// CobInstance.cpp RadAngleToCobShort, SYNC-003): a raw float->short cast
	// is UB once the value leaves short's range, and arm64 -O2 lowers it to
	// fcvtzs-with-saturation (65535.996 -> 65535) instead of the fleet's
	// x86 cvttss2si-then-narrow wrap (-> -1).
	// @step Given the gate test drives ClampRad outputs through the port's defined float→int32→short conversion
	// @step When the boundary angles (0, nextafter(TWOPI, -inf), nextafter(0, +inf), nextafter(TAANG2RAD, +inf)) are converted to TA-short
	// @step Then the converted values equal the fleet's gcc-x86 results: 0, -1 (the 65536 wrap), 0, +1
	CHECK(static_cast<short>(static_cast<int>(ClampRad(0.0f) * RAD2TAANG)) == short(0));
	CHECK(static_cast<short>(static_cast<int>(ClampRad(+std::nextafterf(math::TWOPI, -std::numeric_limits<float>::infinity())) * RAD2TAANG)) == short(-1));
	CHECK(static_cast<short>(static_cast<int>(ClampRad(+std::nextafterf(       0.0f, +std::numeric_limits<float>::infinity())) * RAD2TAANG)) == short( 0));
	CHECK(static_cast<short>(static_cast<int>(ClampRad(+std::nextafterf(TAANG2RAD  , +std::numeric_limits<float>::infinity())) * RAD2TAANG)) == short(+1));
}

TEST_CASE("ClampRadPi")
{
	// Test math::PI (should return -math::PI because PI is not in [-PI, PI))
	CHECK(ClampRadPi(math::PI) == -math::PI);

	// Test std::nextafterf(math::PI, +inf) (should return -math::PI)
	CHECK(ClampRadPi(std::nextafterf(math::PI, +std::numeric_limits<float>::infinity())) == std::nextafterf(-math::PI, +std::numeric_limits<float>::infinity()));

	// Test std::nextafterf(math::PI, -inf) (should return math::PI because it's the largest value < PI)
	CHECK(ClampRadPi(std::nextafterf(math::PI, -std::numeric_limits<float>::infinity())) == std::nextafterf(+math::PI, -std::numeric_limits<float>::infinity()));

	// Test -math::PI (should return -math::PI because -PI is in [-PI, PI))
	CHECK(ClampRadPi(-math::PI) == -math::PI);

	// Test std::nextafterf(-math::PI, +inf) (should return -math::PI)
	CHECK(ClampRadPi(std::nextafterf(-math::PI, +std::numeric_limits<float>::infinity())) == std::nextafterf(-math::PI, +std::numeric_limits<float>::infinity()));

	// Test std::nextafterf(-math::PI, -inf) (should return math::PI because it wraps around)
	CHECK(ClampRadPi(std::nextafterf(-math::PI, -std::numeric_limits<float>::infinity())) == std::nextafterf(+math::PI, -std::numeric_limits<float>::infinity()));

	// Test with -0.0f and verify the result is not negative zero (signbit returns false)
	CHECK_FALSE(std::signbit(ClampRadPi(-0.0f)));

	// Test with +0.0f and verify the result is not negative zero (signbit returns false)
	CHECK_FALSE(std::signbit(ClampRadPi(0.0f)));

	// Test TAANG2RAD conversion to short for [-pi, pi)
	// Same int-intermediate form as the [0, 2pi) block above (SYNC-003).
	// @step Given the gate test drives ClampRadPi outputs through the port's defined float→int32→short conversion
	// @step When the boundary angles (-PI, nextafter(PI, -inf), PI) are converted to TA-short
	// @step Then the converted values equal the fleet's gcc-x86 results: -32768 (exactly at the short minimum), 32767 (truncation of 32767.998, not 32768), -32768
	CHECK(static_cast<short>(static_cast<int>(ClampRadPi(-(math::PI)) * RAD2TAANG)) == short(-32768));
	CHECK(static_cast<short>(static_cast<int>(ClampRadPi(+std::nextafterf(math::PI, -std::numeric_limits<float>::infinity())) * RAD2TAANG)) == short(32767));
	CHECK(static_cast<short>(static_cast<int>(ClampRadPi((math::PI)) * RAD2TAANG)) == short(-32768));
}

