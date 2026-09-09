@done
@sync-gate
@simulation
@determinism
@critical
@SYNC-003
Feature: Synced-code float→short UB sweep matches fleet (gcc-x86) behavior

  """
  Every sweep site in the engine already pins the defined conversion (verified in-tree at commit 8a041014a2 + 7104ab1f76): CobInstance.cpp RadAngleToCobShort, IPathController.cpp GetDeltaHeading (3 sites), GroundMoveType.cpp UpdateDirectControl (2), HoverAirMoveType.cpp UpdateHeading (2), LuaSyncedMoveCtrl.cpp SetHeading, LuaSyncedRead.cpp GetFacingFromHeading. Only the gate test still used the raw UB cast. Full register: docs/SYNC_VALIDATION.md Appendix A.
  """

  # ========================================
  # EXAMPLE MAPPING CONTEXT
  # ========================================
  #
  # BUSINESS RULES:
  #   1. The expected TA-short values must match the fleet's gcc-x86 behavior, which is float->int->short (cvttss2si then narrow): short(nextafter(TWOPI,-inf)*RAD2TAANG) == -1 (65536 wraps), short(ClampRadPi(-PI)*RAD2TAANG) == -32768, short(ClampRadPi(nextafter(PI,-inf))*RAD2TAANG) == 32767.
  #   2. Gate test testClampRad must pin the port's DEFINED conversion (float->int32->short, as used at every sweep site in IPathController/GroundMoveType/HoverAirMoveType/LuaSyncedMoveCtrl/LuaSyncedRead/CobInstance), never a raw float->short cast: the raw cast is UB when the value leaves short's range and produced platform-dependent results (65535 vs -1) for the same bit pattern on arm64.
  #
  # EXAMPLES:
  #   1. testClampRad line 47: static_cast<short>(ClampRad(nextafter(TWOPI,-inf)) * RAD2TAANG) must go through int32 (the port's defined conversion) and equal short(-1); the raw cast is UB and the test currently fails with '-1 == -1' on arm64 (-O2)
  #   2. Engine sweep sites already pin the defined conversion (verified present in tree): CobInstance.cpp RadAngleToCobShort short(int(radAngle*RAD2TAANG)); IPathController.cpp x3 short(int(...)); GroundMoveType.cpp UpdateDirectControl x2; HoverAirMoveType.cpp UpdateHeading x2; LuaSyncedMoveCtrl.cpp SetHeading (short)(int)luaL_checknumber; LuaSyncedRead.cpp GetFacingFromHeading (short)(int)luaL_checknumber
  #
  # ========================================

  Background: User Story
    As a macOS port maintainer
    I want to pin the float→short UB-sweep gate test (testClampRad) to the port's defined float→int→short conversion
    So that the whole sync-UB gate passes on arm64 with the fleet's (gcc-x86) values and no platform-dependent UB remains in the sweep or its gate

  Scenario: TA-short conversion of ClampRad boundary angles matches the fleet
    Given the gate test drives ClampRad outputs through the port's defined float→int32→short conversion
    When the boundary angles (0, nextafter(TWOPI, -inf), nextafter(0, +inf), nextafter(TAANG2RAD, +inf)) are converted to TA-short
    Then the converted values equal the fleet's gcc-x86 results: 0, -1 (the 65536 wrap), 0, +1


  Scenario: TA-short conversion of ClampRadPi boundary angles matches the fleet
    Given the gate test drives ClampRadPi outputs through the port's defined float→int32→short conversion
    When the boundary angles (-PI, nextafter(PI, -inf), PI) are converted to TA-short
    Then the converted values equal the fleet's gcc-x86 results: -32768 (exactly at the short minimum), 32767 (truncation of 32767.998, not 32768), -32768

