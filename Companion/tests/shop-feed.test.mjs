import assert from "node:assert/strict";
import test from "node:test";
import { appendStableProducts, retailerDiverse, shouldContinueShopFeed } from "../shop-feed.mjs";

test("retailer diversity round-robins stores instead of exhausting one catalog", () => {
  const products = [
    { id: "a1", domain: "a.example" }, { id: "a2", domain: "a.example" },
    { id: "b1", domain: "b.example" }, { id: "b2", domain: "b.example" }
  ];
  assert.deepEqual(retailerDiverse(products).map(item => item.id), ["a1", "b1", "a2", "b2"]);
});

test("progressive pages append without reordering, deduplicate, and stop at sixty", () => {
  const published = [{ id: "first" }, { id: "second" }];
  appendStableProducts(published, [{ id: "second" }, ...Array.from({ length: 70 }, (_, index) => ({ id: `new-${index}` }))]);
  assert.deepEqual(published.slice(0, 3).map(item => item.id), ["first", "second", "new-0"]);
  assert.equal(published.length, 60);
});

test("feed keeps building to forty and stops low-confidence expansion after forty-eight", () => {
  assert.equal(shouldContinueShopFeed({ publishedCount: 36, candidatesRemaining: 24, lastWaveConfidence: 0.1 }), true);
  assert.equal(shouldContinueShopFeed({ publishedCount: 48, candidatesRemaining: 12, lastWaveConfidence: 0.54 }), false);
  assert.equal(shouldContinueShopFeed({ publishedCount: 48, candidatesRemaining: 12, lastWaveConfidence: 0.8 }), true);
  assert.equal(shouldContinueShopFeed({ publishedCount: 60, candidatesRemaining: 10, lastWaveConfidence: 1 }), false);
});
