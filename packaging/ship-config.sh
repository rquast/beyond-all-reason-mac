# Machine-local shipping config — NEVER committed (like chobby/ and deps/).
# Points the release pipeline at the engine build dir + Mesa driver prefix to
# package. release-build.sh (line 26) and scripts/visreg.sh source this so the
# release gate and an interactive visreg run cannot drift apart.
#
# Self-contained: resolves the repo root from this file's own location, so it
# works no matter which directory the pipeline is launched from.
_SHIP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Fresh from-source engine build dir for the shipping lane (this tree =
# 2026.07.04 / streflop submodule lane). build-engine.sh configures it fresh.
SHIP_ENGINE_BUILD="${_SHIP_ROOT}/build-engine-2026.07.04"
# Where build-mesa-kk.sh installs the pinned Zink+KosmicKrisp driver.
# NB must be OUTSIDE /Users: the driver's install names are repointed to this
# absolute prefix, and the LESSON-41 builder-path scan refuses a driver that
# embeds any /Users/ path. /opt/homebrew is writable and not /Users.
SHIP_MESA_PREFIX="/opt/homebrew/mesa-native"
unset _SHIP_ROOT
