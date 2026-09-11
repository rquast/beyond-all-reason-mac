@rendering
@wip
@graphics
@graphics-present
@GFX-004
Feature: Eliminate per-unit first-spawn hitch (texture upload + shader compile deferred to first use)
  """
  Integration points: CWorldDrawer::InitPost (rts/Rendering/WorldDrawer.cpp:156-168) calls the new bulk upload after DrainPreloadFutures(0)+UploadVBOs(); CModelLoader::Upload (rts/Rendering/Models/IModelParser.cpp:462) is the per-model entry point (sets model->uploaded, releases shatter indices, runs CheckPieceNormals); CS3OTextureHandler::LoadTexture (rts/Rendering/Textures/S3OTextureHandler.cpp:106) creates the GL texIDs; first-use call sites stay unchanged (SolidObjectDef::LoadModel, UnitDrawer, UnitDrawerData) and become no-ops via the uploaded/texID caches
  """

  # ========================================
  # EXAMPLE MAPPING CONTEXT
  # ========================================
  #
  # BUSINESS RULES:
  #   1. Rendering-only change: nothing under rts/Sim/ or rts/lib/streflop/ changes behavior; the sync-validation gate must pass unchanged
  #   2. Move first-use GL texture upload (glTexImage2D + glGenerateMipmap for S3O model textures) from first spawn to map load, executed after DrainPreloadFutures(0) + UploadVBOs() in CWorldDrawer::InitPost()
  #   3. First-use of a model after the load-time bulk upload must be a no-op (uploaded flag / cached texIDs) so no code path can re-upload or desync texture state
  #   4. PreloadModels=0 must keep working: the lazy first-use upload path stays intact for anything not uploaded at load time (runtime-added models, 3DO atlases, projectile visuals)
  #   5. Accept longer map-load time: move the uploads to the load screen (Option A). Human approved proceeding with Option A on 2026-09-11.
  #   6. Unconditional (upstreamable): applies on all platforms. It only reorders existing load-time work earlier (no new work), so the desktop load-time delta is negligible and the change stays a thin, rebaseable upstream candidate. Human approved proceeding with Option A on 2026-09-11.
  #
  # EXAMPLES:
  #   1. Map load with PreloadModels=1 on an M2-class Mac completes with all S3O model textures uploaded: textureHandlerS3O reports no texID==0 entries for preloaded models, and load time increases by a measured, reported amount (no hard budget set — target: acceptable, progress shown via SetLoadMessage)
  #   2. After the fix, when the first enemy unit of a new type enters view, no [stall] draw gap >150ms line appears in the infolog and no visible camera freeze occurs (Tracy shows no Upload/LoadTexture/glGenerateMipmap span on the main thread at first spawn)
  #   3. A unit with PreloadModels=0 in user settings still works: its texture uploads at first spawn exactly as before the change (lazy path intact)
  #   4. Player spawns a factory and queues a first building of a new type: the building appears without a visible freeze; the (now load-time-paid) texture work does not re-run at spawn
  #
  # QUESTIONS (ANSWERED):
  #   Q: Is a longer map-load time (pure GL texture uploads moved from gameplay to the load screen) acceptable, or should the cost be spread across early frames (Option C in the research doc)?
  #   A: Unconditional (upstreamable): applies on all platforms; only reorders existing load-time work earlier. Human approved 2026-09-11.
  #
  #   Q: Should the change be unconditional (upstreamable, applies on Windows/Linux too) or macOS-gated behind a config/env knob pending desktop load-time measurements?
  #   A: Unconditional (upstreamable): applies on all platforms; only reorders existing load-time work earlier. Human approved 2026-09-11.
  #
  # ========================================
  Background: User Story
    As a macOS player
    I want to play a game without the camera freezing when new unit/building types first appear on screen
    So that smooth, Windows-comparable gameplay through the translation stack

  # Scenarios below cover the *headless-testable* seam of the fix:
  # the model-selection policy that decides which models the load-time
  # bulk GL upload applies to (S3DModel::NeedsFirstUpload).
  # The GL orchestration itself (CModelLoader::UploadAllLoaded ->
  # CModelLoader::Upload -> textureHandlerS3O.LoadTexture) is not
  # headless-testable (myGL.h #error's in unit tests) and is covered by
  # the manual verification procedure in docs/ (Tracy + infolog [stall]).
  Scenario: Load-time bulk upload selects every loaded non-3DO model and skips 3DO and unparsed models
    # Rule 1 (load-time upload after VBOs), Rule 2 (first-use no-op)
    Given 3 S3O model types, 1 3DO model type and 1 unparsed model
    When the bulk-upload selection is evaluated
    Then the 3 S3O models are selected for upload
    And the 3DO model is not selected (atlas textures are preloaded separately)
    And the unparsed model is not selected (its load status is not LOADED)

  Scenario: A model whose first upload already happened is never selected again
    # Rule 2 (uploaded flag makes first-use a no-op)
    Given 1 S3O model is LOADED and marked uploaded
    When the bulk-upload selection is evaluated
    Then the model is not selected for upload

  Scenario: A model still being parsed (or not yet loaded) is not selected
    # Rule 3 (lazy path intact): PreloadModels=0 and late-arriving models
    # keep the on-first-use upload; the bulk pass must not touch them
    Given 1 S3O model with load status LOADING and 1 with NOTLOADED
    When the bulk-upload selection is evaluated
    Then neither model is selected for upload
