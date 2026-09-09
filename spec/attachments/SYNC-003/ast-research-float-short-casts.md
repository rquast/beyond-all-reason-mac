# AST research: float→short cast sites (SYNC-003)

## Query 1 — gate test: `static_cast<short>($$$ARGS)` in testClampRad.cpp

Pattern: `static_cast<short>($$$ARGS)` (AstGrep, language=cpp)
Path: `/Users/rquast/projects/bar/test/engine/System/testClampRad.cpp`

All 7 TA-short cast sites now use the defined int32-intermediate form
(after this work unit's test-side fix):

```
/Users/rquast/projects/bar/test/engine/System/testClampRad.cpp:51:8:static_cast<short>(static_cast<int>(ClampRad(0.0f) * RAD2TAANG))
/Users/rquast/projects/bar/test/engine/System/testClampRad.cpp:52:8:static_cast<short>(static_cast<int>(ClampRad(+std::nextafterf(math::TWOPI, -std::numeric_limits<float>::infinity())) * RAD2TAANG))
/Users/rquast/projects/bar/test/engine/System/testClampRad.cpp:53:8:static_cast<short>(static_cast<int>(ClampRad(+std::nextafterf(       0.0f, +std::numeric_limits<float>::infinity())) * RAD2TAANG))
/Users/rquast/projects/bar/test/engine/System/testClampRad.cpp:54:8:static_cast<short>(static_cast<int>(ClampRad(+std::nextafterf(TAANG2RAD  , +std::numeric_limits<float>::infinity())) * RAD2TAANG))
/Users/rquast/projects/bar/test/engine/System/testClampRad.cpp:85:8:static_cast<short>(static_cast<int>(ClampRadPi(-(math::PI)) * RAD2TAANG))
/Users/rquast/projects/bar/test/engine/System/testClampRad.cpp:86:8:static_cast<short>(static_cast<int>(ClampRadPi(+std::nextafterf(math::PI, -std::numeric_limits<float>::infinity())) * RAD2TAANG))
/Users/rquast/projects/bar/test/engine/System/testClampRad.cpp:87:8:static_cast<short>(static_cast<int>(ClampRadPi((math::PI)) * RAD2TAANG))
```

## Query 2 — engine sweep sites (grep, rts/), all already int-intermediate

```
rts/Sim/Units/Scripts/CobInstance.cpp:55   return static_cast<short>(static_cast<int>(radAngle * RAD2TAANG));   // RadAngleToCobShort
rts/Sim/Path/IPathController.cpp:57        deltaHeading = std::min(deltaHeading, short(int( maxTurnRate)));
rts/Sim/Path/IPathController.cpp:59        deltaHeading = std::max(deltaHeading, short(int(-maxTurnRate)));
rts/Sim/Path/IPathController.cpp:82        const short stopTurnHeading = short(int(oldHeading + (turnBrakeDist * Sign(curTurnSpeed) * brakeDistFactor)));
rts/Sim/Path/IPathController.cpp:93        return short(int(*curTurnSpeedPtr = std::clamp(...)));
rts/Sim/MoveTypes/GroundMoveType.cpp:3322  if (unitCon.left ) { ChangeHeading(short(int(owner->heading + turnRate))); turnSign =  1.0f; }
rts/Sim/MoveTypes/GroundMoveType.cpp:3323  if (unitCon.right) { ChangeHeading(short(int(owner->heading - turnRate))); turnSign = -1.0f; }
rts/Sim/MoveTypes/HoverAirMoveType.cpp:674 owner->AddHeading(std::min(deltaHeading, short(int( turnRate))), ...);
rts/Sim/MoveTypes/HoverAirMoveType.cpp:676 owner->AddHeading(std::max(deltaHeading, short(int(-turnRate))), ...);
rts/Lua/LuaSyncedMoveCtrl.cpp:465          const short heading = (short)(int)luaL_checknumber(L, 2);
rts/Lua/LuaSyncedRead.cpp:1428             lua_pushnumber(L, ::GetFacingFromHeading((short)(int)luaL_checknumber(L, 1)));
```

## Conclusion

- Every synced-code float→short site in rts/ is the defined int32-intermediate
  form (commits 8a041014a2 + 7104ab1f76). No rts/ change required for SYNC-003.
- The only remaining raw float→short UB cast was in the gate test itself
  (testClampRad.cpp lines 46-49, 79-81 pre-fix), which produced an
  arm64/-O2 platform-dependent result (65535 instead of -1) for the
  near-full-turn boundary. Fixed to mirror the engine's defined conversion.
- UnitScript.cpp:1058 (`short(math::asin(...)*RAD2TAANG)`) stays raw:
  asin range is ±π/2, product range ±16384 — always in-bounds, no UB.
