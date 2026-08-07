import test from "node:test";
import assert from "node:assert/strict";
import { eligibleRecommendationItems, recommendationTarget } from "../item-recommendation.mjs";

const wardrobe = [
  { id: "bottom", category: "bottoms", subcategory: "pants" },
  { id: "hat", category: "accessories", subcategory: "hat" },
  { id: "tights", category: "accessories", subcategory: "tights" },
  { id: "purse", category: "accessories", subcategory: "purse" },
  { id: "jewelry", category: "accessories", subcategory: "jewelry" },
  { id: "misc", category: "accessories", subcategory: "misc" },
  { id: "coat", category: "outerwear", subcategory: "coat" }
];

test("broad and precise recommendation targets use the wardrobe taxonomy", () => {
  assert.deepEqual(recommendationTarget({ category: "accessories", subcategory: "hat" }), { category: "accessories", subcategory: "hat" });
  assert.deepEqual(eligibleRecommendationItems(wardrobe, [], { category: "accessories" }).map(item => item.id), ["hat", "tights", "purse", "jewelry", "misc"]);
  assert.deepEqual(eligibleRecommendationItems(wardrobe, [], { category: "accessories", subcategory: "purse" }).map(item => item.id), ["purse"]);
  assert.deepEqual(eligibleRecommendationItems(wardrobe, [], { category: "accessories", subcategory: "jewelry" }).map(item => item.id), ["jewelry"]);
  assert.deepEqual(eligibleRecommendationItems(wardrobe, [], { category: "outerwear", subcategory: "coat" }).map(item => item.id), ["coat"]);
});

test("items already present in the collage are excluded", () => {
  assert.deepEqual(eligibleRecommendationItems(wardrobe, ["bottom"], { category: "bottoms" }), []);
  assert.throws(() => recommendationTarget({ category: "shoes", subcategory: "heels" }), /within the selected category/);
});

test("an untargeted collage request considers every unused category", () => {
  assert.deepEqual(eligibleRecommendationItems(wardrobe, ["hat"], {}).map(item => item.id), ["bottom", "tights", "purse", "jewelry", "misc", "coat"]);
});

test("a user-owned custom subcategory can target matching wardrobe items", () => {
  const customWardrobe = [
    ...wardrobe,
    { id: "custom", category: "tops", subcategory: "custom_date_night", label: "Date-night top" }
  ];
  assert.deepEqual(
    eligibleRecommendationItems(customWardrobe, [], { category: "tops", subcategory: "custom_date_night" }).map(item => item.id),
    ["custom"]
  );
});
