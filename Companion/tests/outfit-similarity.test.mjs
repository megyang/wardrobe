import test from "node:test";
import assert from "node:assert/strict";
import { outfitSimilarityKey, representedOutfitKeys } from "../outfit-similarity.mjs";

const wardrobe = [
  { id: "top", category: "tops" },
  { id: "pants", category: "bottoms" },
  { id: "skirt", category: "bottoms" },
  { id: "sneakers", category: "shoes" },
  { id: "boots", category: "shoes" },
  { id: "scarf", category: "accessories" }
];

test("shoe and accessory swaps keep the same outfit similarity key", () => {
  const first = outfitSimilarityKey(["top", "pants", "sneakers"], wardrobe);
  const variation = outfitSimilarityKey(["top", "pants", "boots", "scarf"], wardrobe);
  const changedFoundation = outfitSimilarityKey(["top", "skirt", "boots"], wardrobe);

  assert.equal(first, variation);
  assert.notEqual(first, changedFoundation);
});

test("saved and recent outfit foundations become represented keys", () => {
  const represented = representedOutfitKeys([
    { garmentIDs: ["top", "pants", "sneakers"] },
    { garmentIDs: ["top", "skirt", "boots"] }
  ], wardrobe);

  assert.equal(represented.size, 2);
  assert.ok(represented.has(outfitSimilarityKey(["top", "pants", "boots"], wardrobe)));
});
