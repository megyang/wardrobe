import assert from "node:assert/strict";
import test from "node:test";
import { allowsShoppingAudience, appendFocusedComplements, appendRetailerDiverseProducts, appendStableProducts, audienceConstrainedQuery, canCompleteFocusedOutfit, deduplicateShopProducts, focusedInspirationSearchBrief, focusedOutfitRoleState, inspirationRequestedRole, passesFocusedInspirationMatch, productRole, retailerDiverse, shouldContinueShopFeed } from "../shop-feed.mjs";

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

test("quality feed caps retailers per page and across the feed without reordering", () => {
  const published = [];
  const wave = [
    ...Array.from({ length: 7 }, (_, index) => ({ id: `a-${index}`, domain: "a.example" })),
    ...Array.from({ length: 4 }, (_, index) => ({ id: `b-${index}`, domain: "b.example" })),
    ...Array.from({ length: 4 }, (_, index) => ({ id: `c-${index}`, domain: "c.example" }))
  ];
  appendRetailerDiverseProducts(published, retailerDiverse(wave), 60, 2, 4);
  assert.equal(published.filter(item => item.domain === "a.example").length, 2);
  assert.ok(Math.max(...["a.example", "b.example", "c.example"].map(domain => published.filter(item => item.domain === domain).length)) <= 2);
  appendRetailerDiverseProducts(published, retailerDiverse(wave.map(item => ({ ...item, id: `next-${item.id}` }))), 60, 2, 4);
  assert.ok(published.filter(item => item.domain === "a.example").length <= 4);
});

test("hybrid candidates deduplicate source IDs, canonical URLs, and merchant titles", () => {
  const values = deduplicateShopProducts([
    { id: "direct", sourceProductID: "same", domain: "shop.example", title: "Ribbed Top", canonicalURL: "https://shop.example/p?utm_source=x" },
    { id: "global-id", sourceProductID: "same", domain: "other.example", title: "Other", canonicalURL: "https://other.example/p" },
    { id: "tracked", sourceProductID: "three", domain: "shop.example", title: "Different", canonicalURL: "https://shop.example/p" },
    { id: "same-title", sourceProductID: "four", domain: "shop.example", title: "Ribbed  Top!", canonicalURL: "https://shop.example/other" }
  ]);
  assert.deepEqual(values.map(item => item.id), ["direct"]);
});

test("feed keeps building to forty and stops low-confidence expansion after forty-eight", () => {
  assert.equal(shouldContinueShopFeed({ publishedCount: 36, candidatesRemaining: 24, lastWaveConfidence: 0.1 }), true);
  assert.equal(shouldContinueShopFeed({ publishedCount: 48, candidatesRemaining: 12, lastWaveConfidence: 0.54 }), false);
  assert.equal(shouldContinueShopFeed({ publishedCount: 48, candidatesRemaining: 12, lastWaveConfidence: 0.8 }), true);
  assert.equal(shouldContinueShopFeed({ publishedCount: 60, candidatesRemaining: 10, lastWaveConfidence: 1 }), false);
});

test("audience preference supports women's, unisex, and men's clothing", () => {
  const womens = { title: "Women's Oxford Shirt" };
  const unisex = { title: "Relaxed Unisex Oxford Shirt" };
  const mens = { title: "Men's Oxford Shirt", canonicalURL: "https://shop.example/products/mens-oxford" };
  assert.equal(allowsShoppingAudience(womens, { clothingAudience: "women" }), true);
  assert.equal(allowsShoppingAudience(mens, { clothingAudience: "women" }), false);
  assert.equal(allowsShoppingAudience(unisex, { clothingAudience: "unisex" }), true);
  assert.equal(allowsShoppingAudience(womens, { clothingAudience: "unisex" }), false);
  assert.equal(allowsShoppingAudience(mens, { clothingAudience: "men" }), true);
  assert.equal(allowsShoppingAudience(womens, { clothingAudience: "men" }), false);
  assert.match(audienceConstrainedQuery("linen shirt", { clothingAudience: "men" }), /men's clothing/i);
});

test("focused outfit shopping fills missing roles instead of duplicating occupied slots", () => {
  const wardrobe = [
    { id: "top", category: "tops" },
    { id: "bottom", category: "bottoms" },
    { id: "shoes", category: "shoes" }
  ];
  const focus = ["top", "bottom", "shoes"];
  assert.equal(canCompleteFocusedOutfit({ title: "Wide leg pants", category: "bottoms" }, wardrobe, focus), false);
  assert.equal(canCompleteFocusedOutfit({ title: "Leather loafers", category: "shoes" }, wardrobe, focus), false);
  assert.equal(canCompleteFocusedOutfit({ title: "Sheer layering turtleneck", category: "tops" }, wardrobe, focus), false);
  assert.equal(canCompleteFocusedOutfit({ title: "Graphic tee", category: "tops" }, wardrobe, focus), false);
  assert.equal(canCompleteFocusedOutfit({ title: "Slip dress", category: "dresses" }, wardrobe, focus), false);
  assert.equal(canCompleteFocusedOutfit({ title: "Patterned tights", category: "accessories" }, wardrobe, focus), true);
  assert.equal(canCompleteFocusedOutfit({ title: "Wool coat", category: "outerwear" }, wardrobe, focus), true);
});

test("a dress prevents replacement tops and bottoms", () => {
  const wardrobe = [{ id: "dress", category: "dresses" }];
  assert.equal(canCompleteFocusedOutfit({ title: "Tank", category: "tops" }, wardrobe, ["dress"]), false);
  assert.equal(canCompleteFocusedOutfit({ title: "Skirt", category: "bottoms" }, wardrobe, ["dress"]), false);
  assert.equal(canCompleteFocusedOutfit({ title: "Beret", category: "accessories" }, wardrobe, ["dress"]), true);
});

test("saved categories override dress-like labels and focused results use each slot once", () => {
  const wardrobe = [{ id: "long-top", label: "Dress top", category: "tops" }];
  assert.equal(productRole(wardrobe[0]), "tops");
  assert.equal(focusedOutfitRoleState(wardrobe, ["long-top"]).missingFoundation, "bottoms");
  const result = appendFocusedComplements([], [
    { id: "skirt-a", title: "Mini skirt", category: "bottoms" },
    { id: "skirt-b", title: "Midi skirt", category: "bottoms" },
    { id: "shoe-a", title: "Loafers", category: "shoes" },
    { id: "shoe-b", title: "Boots", category: "shoes" },
    { id: "hat", title: "Beret", category: "accessories" }
  ], wardrobe, ["long-top"], 6);
  assert.deepEqual(result.map(item => item.id), ["skirt-a", "shoe-a", "hat"]);
});

test("inspiration shopping recognizes explicit top and bottom searches", () => {
  assert.equal(inspirationRequestedRole("Find purchasable tops visually similar to this photo. Return tops only."), "tops");
  assert.equal(inspirationRequestedRole("Find purchasable bottoms visually similar to this photo. Return bottoms only."), "bottoms");
  assert.equal(inspirationRequestedRole("Find the strongest pieces from the whole look"), null);
});

test("focused inspiration retrieval uses only the selected photo's visual traits", () => {
  const brief = focusedInspirationSearchBrief([
    { id: "chosen", silhouettes: ["cropped fitted cardigan"], palette: ["cherry red"], details: ["pearl buttons"], outfitFormula: ["cardigan with capris"], proportions: ["short over long"], layering: [] },
    { id: "other", silhouettes: ["oversized hoodie"], palette: ["gray"], details: [], outfitFormula: [], proportions: [], layering: [] }
  ], ["chosen"], "tops");
  assert.match(brief, /cropped fitted cardigan/);
  assert.match(brief, /cherry red/);
  assert.doesNotMatch(brief, /oversized hoodie/);
});

test("focused inspiration products must match the exact photo in silhouette and color", () => {
  const strong = { confidence: 0.9, tasteFit: 0.88, silhouetteFit: 0.84, colorFit: 0.79, constructionFit: 0.72, matchedInspirationIDs: ["chosen"] };
  assert.equal(passesFocusedInspirationMatch(strong, ["chosen"]), true);
  assert.equal(passesFocusedInspirationMatch({ ...strong, silhouetteFit: 0.5 }, ["chosen"]), false);
  assert.equal(passesFocusedInspirationMatch({ ...strong, colorFit: 0.4 }, ["chosen"]), false);
  assert.equal(passesFocusedInspirationMatch({ ...strong, matchedInspirationIDs: ["other"] }, ["chosen"]), false);
});
