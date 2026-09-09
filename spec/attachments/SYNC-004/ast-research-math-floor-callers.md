# AST research: math::floor resolution + synced call sites (SYNC-004)

## Query 1 — the synced Lua math.floor callin (the raptors desync origin)

Pattern: `math_floor (lua_State *L)` (AstGrep, language=cpp)
Path: `/Users/rquast/projects/bar/rts/lib/lua/src/lmathlib.cpp`

```
/Users/rquast/projects/bar/rts/lib/lua/src/lmathlib.cpp:86:12:math_floor (lua_State *L)
   body: lua_pushnumber(L, math::floor(luaL_checknumber_noassert(L, 1)));
```

Include order in lmathlib.cpp (the exact order the test mirrors):
   line 10:  #include "streflop_cond.h"
   line 11:  #include "System/FastMath.h"

With STREFLOP_NEON defined, streflop_cond.h defines exact-match
`math::floor(float)` / `math::floor(double)` overloads (streflop_cond.h:64-65)
that outcompete `fastmath::floor` (a template, via `using fastmath::floor`
at FastMath.h:223). So the synced Lua `math.floor` resolves to the streflop
overload on BOTH arches.

## Query 2 — streflop floor implementation (submodule @ 570f86f)

`rts/lib/streflop/streflop_cond.h:64`
   inline float floor(float x) { return streflop::floor(Simple(x)); }
`rts/lib/streflop/streflop_cond.h:65`
   inline double floor(double x) { return streflop::floor(Double(x)); }

`rts/lib/streflop/SMath.h:244` / `:452`
   streflop::floor -> streflop_libm::__floorf / streflop_libm::__floor

`rts/lib/streflop/libm/flt-32/s_floorf.cpp:41`  (Simple __floorf) — pure
integer bit-twiddling on the IEEE-754 bits; no arch-specific intrinsics.
NaN in -> NaN out (j0==0x80 path, line 67); |x|>=2^23 integral -> x
unchanged (line 68). Same code shape in libm/dbl-64/s_floor.cpp:38.

Because the implementation is pure bit manipulation, the result is
arch-independent; the committed tools/sync-test references confirm it:
floor: NEON=2005 rows, SSE=1985 rows, 1985/1985 common inputs, 0 mismatches
(incl. edge rows floor(7FC00000)->7FC00000, floor(FFC00000)->FFC00000,
floor(7F800000)->7F800000, floor(7F7FFFFF)->7F7FFFFF identity).

## Query 3 — synced (rts/Sim) call sites that rely on math::floor parity

Grep `math::floor` under rts/Sim (synced code — any arch divergence here
desyncs lockstep):

```
rts/Sim/Misc/QuadField.cpp:208          math::floor(start.x * invQuadSize.x)
rts/Sim/Misc/QuadField.cpp:209          math::floor(start.z * invQuadSize.y)
rts/Sim/Misc/QuadField.cpp:294          math::floor(baseTo.z * invQuadSize.y)
rts/Sim/Units/CommandAI/BuilderCAI.cpp:596  math::floor(c.GetParam(0) / SQUARE_SIZE)
rts/Sim/Units/CommandAI/BuilderCAI.cpp:597  math::floor(c.GetParam(2) / SQUARE_SIZE)
rts/Sim/Projectiles/ExplosionGenerator.cpp:744  val -= (*(float*)code) * math::floor(val / (*(float*)code))
rts/Sim/Projectiles/ExplosionGenerator.cpp:749  math::floor(spring::SafeDivide(val, (*(float*)code)))
rts/Sim/MoveTypes/MoveType.h:86         std::clamp(math::floor((speed/maxSpeed)*nsteps), 0.0f, nsteps-1.0f)
rts/Sim/MoveTypes/StrafeAirMoveType.cpp:1304  math::floor(math::log(...)/math::log(r))
rts/Sim/MoveTypes/GroundMoveType.cpp:1561     math::floor(skidRotSpeed + skidRotAccel + 0.5f)
rts/Sim/MoveTypes/GroundMoveType.cpp:1590     math::floor(skidRotSpeed + skidRotAccel*(rotRemTime-1.0f) + 0.5f)
rts/Sim/MoveTypes/GroundMoveType.cpp:1594     math::floor(skidRotSpeed) != math::floor(skidRotSpeed + skidRotAccel)
```

These all feed bounded in-range floats (positions, rates) — the identity/
truncation region where IEEE floor is well-defined and arch-independent.

## Query 4 — fastmath::floor direct callers (the only remaining
arch-divergent floor path)

Grep `fastmath::floor` (excl. the using-declaration):
   rts/System/FastMath.h:223  using fastmath::floor;   (only reference)
No call site in rts/ invokes fastmath::floor directly. The cvtt-class
divergence (NaN: fcvtzs->0 on arm64 vs cvttss2si->INT_MIN on x86) is
therefore unreachable through the resolved math::floor on this base.

## Conclusion

On the 2026.07.04 base the cvtt/INT_MIN class is closed at the floor path:
math::floor resolves to the shared, bit-exact, arch-independent streflop
libm floor on both arches. The regression test (testFloorSemantics.cpp)
pins the resolved output bits so a cherry-pick of the 2025.06.24 cvtt
emulation (c20b863148) or an arch-divergent streflop pin fails the gate.
