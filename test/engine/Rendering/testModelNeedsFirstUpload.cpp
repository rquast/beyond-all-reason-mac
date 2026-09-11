/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

/**
 * Feature: spec/features/model-texture-preload.feature
 *
 * This test file validates the acceptance criteria defined in the feature file.
 * Each Gherkin scenario maps to one Catch2 SCENARIO (top-level test case).
 *
 * It covers the headless-testable seam of GFX-004: the model-selection policy
 * (S3DModel::NeedsFirstUpload) that decides which models the load-time bulk
 * GL upload (CModelLoader::UploadAllLoaded) applies to. The GL orchestration
 * itself is not headless-testable (myGL.h #error's under UNIT_TEST); see the
 * manual verification procedure in docs/.
 *
 * S3DModel instances are constructed in place (std::array, no moves) so the
 * GL-bound S3DModel move ctor/assignment (defined in 3DModel.cpp, which
 * includes myGL.h) is never needed at link time — only the storage global it
 * touches (transformsMemStorage) is.
 */

#include <catch_amalgamated.hpp>

#include <array>

#include "Rendering/Models/3DModel.hpp"
#include "System/Transform.hpp"

// The S3DModel default ctor builds a ScopedTransformMemAlloc(0u); its inline
// dtor (ModelsMemStorage.h) references TransformsMemStorage::Free and
// Transform::Zero() when a valid slot is freed. This test never allocates a
// slot (Allocate(0) returns INVALID_INDEX, so the dtor early-returns), so this
// stub is link-only and never executes.
const Transform& Transform::Zero()
{
	static const Transform zero;
	return zero;
}

namespace {

// Mirrors CModelLoader::UploadAllLoaded()'s selection loop exactly:
// count every model that still owes the deferred first-use GL upload.
template<size_t N>
size_t CountSelected(const std::array<S3DModel, N>& models)
{
	size_t count = 0;
	for (const auto& m: models) {
		if (m.NeedsFirstUpload())
			++count;
	}
	return count;
}

using LoadStatus = S3DModel::LoadStatus;

} // namespace

SCENARIO("Load-time bulk upload selects every loaded non-3DO model and skips 3DO and unparsed models")
{
	// @step Given 3 S3O model types, 1 3DO model type and 1 unparsed model
	// (the "unparsed model" is a default-constructed S3DModel: loadStatus NOTLOADED)
	std::array<S3DModel, 5> models;
	{
		auto set = [&](size_t i, ModelType type, LoadStatus st, bool up) {
			models[i].type = type;
			models[i].loadStatus = st;
			models[i].uploaded = up;
		};
		set(0, MODELTYPE_S3O, LoadStatus::LOADED, false);
		set(1, MODELTYPE_S3O, LoadStatus::LOADED, false);
		set(2, MODELTYPE_S3O, LoadStatus::LOADED, false);
		set(3, MODELTYPE_3DO, LoadStatus::LOADED, false);
		// index 4: left default-constructed (unparsed: NOTLOADED)
	}

	// @step When the bulk-upload selection is evaluated
	const auto selected = CountSelected(models);

	// @step Then the 3 S3O models are selected for upload
	REQUIRE(selected == 3);
	REQUIRE(models[0].NeedsFirstUpload());
	REQUIRE(models[1].NeedsFirstUpload());
	REQUIRE(models[2].NeedsFirstUpload());

	// @step And the 3DO model is not selected (atlas textures are preloaded separately)
	REQUIRE_FALSE(models[3].NeedsFirstUpload());

	// @step And the unparsed model is not selected (its load status is not LOADED)
	REQUIRE_FALSE(models[4].NeedsFirstUpload());
}

SCENARIO("A model whose first upload already happened is never selected again")
{
	// @step Given 1 S3O model is LOADED and marked uploaded
	std::array<S3DModel, 2> models;
	models[0].type = MODELTYPE_S3O;
	models[0].loadStatus = LoadStatus::LOADED;
	models[0].uploaded = false;
	models[1].type = MODELTYPE_S3O;
	models[1].loadStatus = LoadStatus::LOADED;
	models[1].uploaded = true;

	// @step When the bulk-upload selection is evaluated
	const auto selected = CountSelected(models);

	// @step Then the model is not selected for upload
	REQUIRE(selected == 1);
	REQUIRE(models[0].NeedsFirstUpload());
	REQUIRE_FALSE(models[1].NeedsFirstUpload());
}

SCENARIO("A model still being parsed (or not yet loaded) is not selected")
{
	// @step Given 1 S3O model with load status LOADING and 1 with NOTLOADED
	std::array<S3DModel, 2> models;
	models[0].type = MODELTYPE_S3O;
	models[0].loadStatus = LoadStatus::LOADING;
	models[1].type = MODELTYPE_S3O;
	models[1].loadStatus = LoadStatus::NOTLOADED;

	// @step When the bulk-upload selection is evaluated
	const auto selected = CountSelected(models);

	// @step Then neither model is selected for upload
	REQUIRE(selected == 0);
	REQUIRE_FALSE(models[0].NeedsFirstUpload());
	REQUIRE_FALSE(models[1].NeedsFirstUpload());
}
