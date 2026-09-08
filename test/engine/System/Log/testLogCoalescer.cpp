/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
/**
 * Feature: spec/features/log-repeat-coalescer.feature
 *
 * Validates the generic near-identical log repeat-coalescer added by the macOS
 * port (System/Log/Backend.cpp, commit b408ad288d). It collapses floods of
 * structurally-identical lines (numeric tokens varying) at the one choke point
 * every record passes through, emitting "previous line repeated N more time(s)"
 * rollups instead of letting them bloat infolog.txt.
 *
 * Drives the public backend C API (log_backend_record + a capture sink) so the
 * test is self-contained and does not depend on the console/file sinks.
 *
 * NOTE: the coalescer's slot table is process-global state with no public
 * reset, so every case uses a unique section name to stay deterministic
 * regardless of what earlier cases left in the 8 tracked slots.
 */

#include "System/Log/Backend.h"        // log_backend_registerSink / _flushRepeats
#include "System/Log/DefaultFilter.h"  // log_filter_setRepeatLimit / _getRepeatLimit
#include "System/Log/Level.h"

#include <cstdarg>

// log_backend_record is defined in Backend.cpp but not declared in a public
// header (only extern in DefaultFilter.cpp). Declare the C symbol here so the
// test can drive records straight through the backend choke point.
extern "C" {
void log_backend_record(int level, const char* section, const char* fmt, va_list arguments);
}

#include <catch_amalgamated.hpp>

#include <string>
#include <vector>

namespace {
	// Capture sink: record every (level, record) the backend emits.
	std::vector<std::string> emitted;
	std::vector<int> emittedLevels;

	void captureSink(int level, const char*, const char* record)
	{
		emittedLevels.push_back(level);
		emitted.emplace_back(record != nullptr ? record : "");
	}

	void resetSink()
	{
		emitted.clear();
		emittedLevels.clear();
	}

	int countContaining(const std::string& needle)
	{
		int n = 0;
		for (const auto& s : emitted)
			if (s.find(needle) != std::string::npos)
				++n;
		return n;
	}

	// Sum the "repeated N more" counts across every rollup line.
	int sumRollupCounts()
	{
		const char* needle = "previous line repeated ";
		const size_t needleLen = std::strlen(needle);
		long long total = 0;
		for (const auto& s : emitted) {
			const auto p = s.find(needle);
			if (p == std::string::npos)
				continue;
			std::string::size_type start = p + needleLen;
			std::string::size_type end = s.find(' ', start);
			std::string num = s.substr(start, end == std::string::npos ? std::string::npos : end - start);
			total += std::stoll(num);
		}
		return static_cast<int>(total);
	}

	// Drive a record through the backend with a variadic format string.
	void record(int level, const char* section, const char* fmt, ...)
	{
		va_list ap;
		va_start(ap, fmt);
		log_backend_record(level, section, fmt, ap);
		va_end(ap);
	}

	// The coalescer only matters when exact-duplicate suppression is OFF; with
	// the default repeat limit (1) identical lines are dropped before the
	// coalescer sees them. RAII: restore the previous limit on scope exit.
	struct RepeatLimitGuard {
		const int prev;
		RepeatLimitGuard() : prev(log_filter_getRepeatLimit())
		{
			log_filter_setRepeatLimit(0);
		}
		~RepeatLimitGuard()
		{
			log_filter_setRepeatLimit(prev);
		}
	};

	// Register the capture sink exactly once for the whole test binary.
	struct SinkRegistrar {
		SinkRegistrar() { log_backend_registerSink(&captureSink); }
	};
	static SinkRegistrar sinkRegistrar;
}

// ROLLUP_EVERY in Backend.cpp is 100: the 100th suppressed record of a pattern
// triggers a rollup; log_backend_flushRepeats() emits any residual tail.
static const int ROLLUP_EVERY = 100;

TEST_CASE("coalescer collapses a numeric-token flood into a rollup")
{
	// @step Given the log backend coalescer is active and exact-duplicate suppression is disabled
	RepeatLimitGuard lim;
	resetSink();

	const char* section = "CoalesceStall";
	const int level = 40; // LOG_LEVEL_WARNING

	// @step When the engine logs one stall warning, then 101 more with only their numbers changing
	// 1st: distinct line -> passes through in full.
	record(level, section, "[stall] draw gap 152ms (drawFrame=1, stalls=1)");

	// 2..101: near-identical (only the numbers differ) -> suppressed, counted.
	for (int i = 2; i <= 101; ++i)
		record(level, section, "[stall] draw gap %dms (drawFrame=%d, stalls=%d)", i * 150, i, i);

	log_backend_flushRepeats(); // emit the residual tail

	// @step Then exactly one full stall warning is emitted, and the 100 suppressed duplicates are accounted for in a 'previous line repeated N more time(s)' rollup carrying the stall section
	// Exactly one full record for the pattern survived; no per-line flood.
	CHECK(countContaining("[stall] draw gap") == 1);
	CHECK(countContaining("draw gap 152ms") == 1);

	// All 100 suppressed records are accounted for in the rollup(s):
	// record 101 hit ROLLUP_EVERY exactly, so the tail flush adds nothing.
	CHECK(countContaining("previous line repeated") >= 1);
	CHECK(sumRollupCounts() == 100);

	// The rollup carries the section it collapsed and the original level.
	CHECK(countContaining("CoalesceStall") >= 1);
	CHECK(!emittedLevels.empty());
	CHECK(emittedLevels.back() == level);
}

TEST_CASE("coalescer keeps two interleaved flood patterns distinct")
{
	// @step Given the log backend coalescer is active and exact-duplicate suppression is disabled
	RepeatLimitGuard lim;
	resetSink();

	// @step When the engine logs five input-motion lines and five stall draw-gap lines interleaved, each with only its numbers changing
	// Two independent high-frequency patterns interleave; the multi-slot design
	// collapses each into its own rollup without breaking the other's run.
	for (int i = 0; i < 5; ++i) {
		record(40, "CoalesceInputA", "[input] motion pos=%d rel=%d", i, i);
		record(40, "CoalesceStallB", "[stall] draw gap 300ms (drawFrame=%d, stalls=%d)", i, i);
	}
	log_backend_flushRepeats();

	// @step Then each pattern passes through exactly once, and its four suppressed repeats are accounted in its own rollup carrying its own section
	// Both patterns' first lines passed through exactly once each.
	CHECK(countContaining("motion pos=0 rel=0") == 1);
	CHECK(countContaining("draw gap 300ms (drawFrame=0, stalls=0)") == 1);

	// Each pattern's 4 suppressed repeats are accounted, in total.
	CHECK(sumRollupCounts() == 8);
	// The rollups report each pattern's own section, not a merged one.
	CHECK(countContaining("CoalesceInputA") >= 1);
	CHECK(countContaining("CoalesceStallB") >= 1);
}

TEST_CASE("coalescer does not merge structurally different lines")
{
	// @step Given the log backend coalescer is active and exact-duplicate suppression is disabled
	RepeatLimitGuard lim;
	resetSink();

	// @step When the engine logs two texture-load lines from the same section that differ by a non-numeric word
	// Same section, same level, but a different non-numeric token -> different
	// signature, so both must pass through in full (no false coalescing).
	record(40, "CoalesceCfg", "loaded texture a");
	record(40, "CoalesceCfg", "loaded texture b");

	// @step Then both lines pass through in full and no repeat rollup is emitted
	CHECK(countContaining("loaded texture a") == 1);
	CHECK(countContaining("loaded texture b") == 1);
	CHECK(countContaining("previous line repeated") == 0);
}

TEST_CASE("structurally different lines stay distinct even with numeric noise")
{
	// @step Given the log backend coalescer is active and exact-duplicate suppression is disabled
	RepeatLimitGuard lim;
	resetSink();

	// @step When the engine logs two path lines that differ by a non-numeric word while their trailing numbers also differ
	// The two lines differ by a NON-numeric word (alpha/beta), not just their
	// numbers, so their signatures differ and BOTH must pass through in full.
	// (A lone '->' is punctuation, not a numeric token, and stays in the
	// signature, so it too keeps structurally-different lines distinct.)
	record(40, "CoalescePunct", "path -> alpha 1");
	record(40, "CoalescePunct", "path -> beta 2");

	// @step Then both lines pass through in full and no repeat rollup is emitted
	CHECK(countContaining("alpha") == 1);
	CHECK(countContaining("beta") == 1);
	CHECK(countContaining("previous line repeated") == 0);
}
