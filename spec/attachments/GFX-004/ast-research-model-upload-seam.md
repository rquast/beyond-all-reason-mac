# AST Research: GFX-004 — model load/upload seam

Date: 2026-09-11 · Tool: ast-grep (structural scan of `rts/Rendering/`)
Purpose: confirm the shape of the existing per-model upload path that
`CModelLoader::UploadAllLoaded()` (GFX-004) reuses, and that the call site
(`CWorldDrawer::InitPost`) sits inside the load-screen preload section.

## Entities of interest

- `S3DModel` (`rts/Rendering/Models/3DModel.hpp`) — per-model render-state
  record: `type` (MODELTYPE_S3O / MODELTYPE_3DO / ...), `loadStatus`
  (NOTLOADED / LOADING / LOADED), `uploaded` (GL render data uploaded flag),
  `pieceObjects`, VBO ids.
- `CModelLoader` (`rts/Rendering/Models/IModelParser.h`) — owns
  `std::vector<S3DModel> models`; per-model `Upload(S3DModel*)` is the single
  entry point that pays the deferred GL cost; `DrainPreloadFutures(num)`
  drains async parse futures; `UploadAllLoaded()` (new, GFX-004) selects with
  `S3DModel::NeedsFirstUpload()` and calls `Upload()` per model.
- `CWorldDrawer::InitPost()` (`rts/Rendering/WorldDrawer.cpp:80`) — load-screen
  finalization; the `preloadMode` block drains futures, `UploadVBOs()` under
  `CLoadLock::GetUniqueLock()`, then (GFX-004) `modelLoader.UploadAllLoaded()`.

## Structural anchors (verified against the tree)

### `CModelLoader::Upload(S3DModel* model) const` — IModelParser.cpp:477

```
void CModelLoader::Upload(S3DModel* model) const {
	RECOIL_DETAILED_TRACY_ZONE;
	if (model->uploaded) //already uploaded
		return;                                  // <-- idempotency guard:
                                                // first-use after bulk upload
                                                // is a no-op
	assert(Threading::IsMainThread() ||
	       Threading::IsGameLoadThread());

	{
		auto lock = CLoadLock::GetUniqueLock(); // recursive; safe re-lock
		S3DModelVAO::GetInstance().UploadVBOs();

		// 3DO atlases are preloaded in C3DOTextureHandler::Init()
		if (model->type != MODELTYPE_3DO) {
			// make sure textures (already preloaded) are fully loaded
			textureHandlerS3O.LoadTexture(model); // glTexImage2D +
		}                                        // glGenerateMipmap
	}

	for (auto* p : model->pieceObjects) {
		p->ReleaseShatterIndices();
	}

	// warn about models with bad normals (skip 3DO: auto-calculated)
	if (model->type != MODELTYPE_3DO)
		CheckPieceNormals(model, model->GetRootPiece());

	model->uploaded = true;
}
```

Observations driving the design:

1. `if (model->uploaded) return;` — the per-model path is already idempotent,
   so a bulk pass + later first use cannot double-upload.
2. The 3DO branch is *inside* `Upload()` too; the `NeedsFirstUpload()`
   predicate (non-3DO) only skips 3DO models from the *bulk* loop to avoid
   their pointless VBO re-upload bookkeeping — 3DO first-use behavior is
   unchanged either way.
3. Thread assert matches `LuaVFSDownload.cpp:289` / `ExplosionGenerator.cpp:1090`
   convention: `IsMainThread() || IsGameLoadThread()`.

### `CModelLoader::UploadAllLoaded()` (new) — IModelParser.cpp:403

```
void CModelLoader::UploadAllLoaded()
{
	RECOIL_DETAILED_TRACY_ZONE;
	assert(Threading::IsMainThread() || Threading::IsGameLoadThread());
	for (auto& m: models) {
		if (!m.NeedsFirstUpload())
			continue;
		Upload(&m);
	}
}
```

### `CWorldDrawer::InitPost()` call site — WorldDrawer.cpp:156-175

```
	loadscreen->SetLoadMessage("Finalizing Models");
	modelLoader.DrainPreloadFutures(0);
	auto& mv = S3DModelVAO::GetInstance();
	if (preloadMode) {
		{
			auto lock = CLoadLock::GetUniqueLock();
			mv.UploadVBOs();
			modelLoader.UploadAllLoaded();   // <- GFX-004, after VBOs
		}
		mv.SetSafeToDeleteVectors();
		modelLoader.LogErrors();
		CModelsLock::SetThreadSafety(false); //all models are already preloaded
	}
```

### `S3DModel::NeedsFirstUpload()` (new, inline) — 3DModel.hpp:70-93

```
bool NeedsFirstUpload() const
{
	if (loadStatus != LoadStatus::LOADED) return false; // dummy + unparsed
	if (uploaded) return false;                        // already uploaded
	return (type != MODELTYPE_3DO);                    // atlases preloaded
}
```

## First-use call sites (unchanged by the fix; become no-ops via caches)

- `SolidObjectDef::LoadModel()` — per unit-type model load at spawn.
- `CUnitDrawer` / `CUnitDrawerData` — per-unit first draw.
All of these route through `CModelLoader::Upload()` (directly or via
`textureHandlerS3O` texID caches), so after the bulk pass they hit
`model->uploaded == true` and early-return.
