import test from "node:test";
import assert from "node:assert/strict";
import { catalogEditPrompt, catalogPrompt } from "../prompts.mjs";
import { normalizeSubcategory } from "../category-taxonomy.mjs";
import { isAnalysisJobOverdue } from "../job-lifecycle.mjs";
import { hasValidOutfitComposition } from "../outfit-rules.mjs";
import { SerialQueue } from "../serial-queue.mjs";
import { withAbortTimeout } from "../timeout.mjs";
import { PriorityQueue } from "../priority-queue.mjs";
import { itemRecommendationSchema, outfitSchema, outfitSelectionSchema, wardrobeGapSchema } from "../response-schemas.mjs";
import { inspirationPrompt, inspirationSchema } from "../inspiration.mjs";

test("purchase layout contract keeps candidate outside owned IDs", () => {
  const owned = new Set(["a", "b", "c"]);
  const response = { verdict: "buy", outfits: [{ garmentIDs: ["a", "b"] }] };
  assert.equal(["buy", "maybe", "skip"].includes(response.verdict), true);
  assert.equal(response.outfits.every(outfit => outfit.garmentIDs.every(id => owned.has(id))), true);
});

test("AI style cannot contain an unknown ID", () => {
  const owned = new Set(["a", "b"]);
  const suggested = ["a", "outside"];
  assert.equal(suggested.every(id => owned.has(id)), false);
});

test("outfit response schema uses only Codex-supported array constraints", () => {
  const schema = outfitSchema(["owned-1", "owned-2"], 3, 3);
  const garmentIDs = schema.properties.outfits.items.properties.garmentIDs;

  assert.equal(garmentIDs.uniqueItems, undefined);
  assert.deepEqual(garmentIDs.items.enum, ["owned-1", "owned-2"]);
});

test("inspiration analysis is a reusable fixed style vector", () => {
  const axes = inspirationSchema.properties.vector.required;
  assert.deepEqual(axes, ["minimal", "maximal", "relaxed", "tailored", "romantic", "edgy", "sporty", "vintage", "classic", "experimental", "layered", "colorful"]);
  assert.match(inspirationPrompt(), /cached and reused/i);
  assert.ok(inspirationSchema.required.includes("outfitFormula"));
  assert.ok(inspirationSchema.required.includes("proportions"));
  assert.doesNotMatch(inspirationPrompt(), /identity.*infer/i);
});

test("fashion critic selects three known candidates", () => {
  const schema = outfitSelectionSchema(["candidate-a", "candidate-b", "candidate-c"]);
  const selection = schema.properties.selections;
  assert.equal(selection.minItems, 3);
  assert.equal(selection.maxItems, 3);
  assert.deepEqual(selection.items.properties.candidateID.enum, ["candidate-a", "candidate-b", "candidate-c"]);
});

test("collage recommendations return up to two owned IDs", () => {
  const schema = itemRecommendationSchema(["one", "two", "three"]);
  const ids = schema.properties.garmentIDs;
  assert.equal(ids.minItems, 1);
  assert.equal(ids.maxItems, 2);
  assert.deepEqual(ids.items.enum, ["one", "two", "three"]);
});

test("wardrobe gaps stay broad and taxonomy-backed", () => {
  const schema = wardrobeGapSchema(["tops", "bottoms"], ["tank_top", "pants"]);
  const gap = schema.properties.gaps.items;
  assert.deepEqual(gap.properties.category.enum, ["tops", "bottoms"]);
  assert.deepEqual(gap.properties.subcategory.enum, ["none", "tank_top", "pants"]);
  assert.ok(gap.required.includes("searchQuery"));
});

test("outfits allow explicit two-piece torso layers but only one bottom and dress", () => {
  const wardrobe = [
    { id: "top-1", category: "tops", subcategory: "long_sleeve", label: "Plain fitted long sleeve" },
    { id: "top-2", category: "tops", subcategory: "tank_top" },
    { id: "bottom-1", category: "bottoms", subcategory: "pants" }, { id: "bottom-2", category: "bottoms", subcategory: "shorts" },
    { id: "dress-1", category: "dresses" }, { id: "dress-2", category: "dresses" },
    { id: "coat", category: "outerwear" }
  ];
  const dressLayer = [{ garmentID: "top-1", placement: "under" }, { garmentID: "dress-1", placement: "main" }];
  const topLayer = [{ garmentID: "top-1", placement: "under" }, { garmentID: "top-2", placement: "main" }];
  assert.equal(hasValidOutfitComposition(["dress-1", "bottom-1", "top-1", "coat"], wardrobe, null, dressLayer), true);
  assert.equal(hasValidOutfitComposition(["top-1", "top-2"], wardrobe, null, topLayer), true);
  assert.equal(hasValidOutfitComposition(["top-1", "top-2"], wardrobe), false);
  assert.equal(hasValidOutfitComposition(["bottom-1", "bottom-2"], wardrobe), false);
  assert.equal(hasValidOutfitComposition(["dress-1", "dress-2"], wardrobe), false);
  assert.equal(hasValidOutfitComposition(["bottom-1", "coat"], wardrobe, { category: "dresses" }), true);
  assert.equal(hasValidOutfitComposition(["bottom-2", "coat"], wardrobe, { category: "dresses" }), true);
  assert.equal(hasValidOutfitComposition(["dress-1", "coat"], wardrobe, { category: "dresses" }), false);
  assert.equal(hasValidOutfitComposition(["top-1"], wardrobe, { category: "tops", subcategory: "tank_top" }, [
    { garmentID: "top-1", placement: "under" }, { garmentID: "__candidate__", placement: "main" }
  ]), true);
});

test("outfit rules leave visual taste to Luna but require explicit valid layering", () => {
  const wardrobe = [
    { id: "plain-long", category: "tops", subcategory: "long_sleeve", label: "Plain fitted long sleeve" },
    { id: "ruffled-long", category: "tops", subcategory: "long_sleeve", label: "Ruffled printed long sleeve" },
    { id: "tank", category: "tops", subcategory: "tank_top" },
    { id: "tee", category: "tops", subcategory: "t_shirt" },
    { id: "dress", category: "dresses" }
  ];
  assert.equal(hasValidOutfitComposition(["plain-long", "tank"], wardrobe, null, [
    { garmentID: "plain-long", placement: "under" }, { garmentID: "tank", placement: "main" }
  ]), true);
  assert.equal(hasValidOutfitComposition(["ruffled-long", "tank"], wardrobe, null, [
    { garmentID: "ruffled-long", placement: "under" }, { garmentID: "tank", placement: "main" }
  ]), true);
  assert.equal(hasValidOutfitComposition(["plain-long", "tee"], wardrobe, null, [
    { garmentID: "plain-long", placement: "under" }, { garmentID: "tee", placement: "main" }
  ]), true);
  assert.equal(hasValidOutfitComposition(["dress", "tank"], wardrobe, null, [
    { garmentID: "dress", placement: "under" }, { garmentID: "tank", placement: "main" }
  ]), true);
  assert.equal(hasValidOutfitComposition(["plain-long", "tank"], wardrobe, null, [
    { garmentID: "plain-long", placement: "under" }, { garmentID: "missing", placement: "main" }
  ]), false);
});

test("durable analysis jobs expose state without leaking their request", () => {
  const persisted = {
    id: "11111111-1111-1111-1111-111111111111",
    kind: "analyze",
    state: "processing",
    owner: "private-owner-hash",
    request: { imageBase64: "private-image" },
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  const publicJob = (({ id, kind, state, createdAt, updatedAt, result = null, error = null }) => ({ id, kind, state, createdAt, updatedAt, result, error }))(persisted);
  assert.equal(publicJob.state, "processing");
  assert.equal("request" in publicJob, false);
  assert.equal("owner" in publicJob, false);
});

test("queued imports live for 24 hours and processing gets its own timeout", () => {
  const now = Date.parse("2026-08-03T12:00:00.000Z");
  const hoursAgo = hours => new Date(now - hours * 60 * 60 * 1000).toISOString();
  assert.equal(isAnalysisJobOverdue({ state: "queued", createdAt: hoursAgo(23.99) }, now), false);
  assert.equal(isAnalysisJobOverdue({ state: "queued", createdAt: hoursAgo(24) }, now), true);
  assert.equal(isAnalysisJobOverdue({ state: "processing", createdAt: hoursAgo(23), processingStartedAt: hoursAgo(0.99) }, now), false);
  assert.equal(isAnalysisJobOverdue({ state: "processing", createdAt: hoursAgo(23), processingStartedAt: hoursAgo(1) }, now), true);
});

test("garment subcategories cannot cross parent categories", () => {
  assert.equal(normalizeSubcategory("tops", "tank_top"), "tank_top");
  assert.equal(normalizeSubcategory("bottoms", "mini_skirt"), "mini_skirt");
  assert.equal(normalizeSubcategory("bottoms", "midi_skirt"), "midi_skirt");
  assert.equal(normalizeSubcategory("bottoms", "maxi_skirt"), "maxi_skirt");
  assert.equal(normalizeSubcategory("bottoms", "skirt"), null);
  assert.equal(normalizeSubcategory("bottoms", "pants"), "pants");
  assert.equal(normalizeSubcategory("tops", "pants"), null);
  assert.equal(normalizeSubcategory("dresses", "misc"), null);
  assert.equal(normalizeSubcategory("accessories", "misc"), "misc");
  assert.equal(normalizeSubcategory("accessories", "purse"), "purse");
  assert.equal(normalizeSubcategory("accessories", "jewelry"), "jewelry");
});

test("catalog prompt requests a removable solid chroma product background", () => {
  const prompt = catalogPrompt({ label: "purple asymmetric skirt", observed: "purple leopard print and uneven hem", unknowns: ["back closure"] });
  assert.match(prompt, /ecommerce catalog cutout/i);
  assert.match(prompt, /chroma green \(#00FF00\)/i);
  assert.match(prompt, /do not draw transparency, a checkerboard, pixel grid/i);
  assert.match(prompt, /every edge fully visible/i);
  assert.match(prompt, /not a fashion visualization/i);
  assert.match(prompt, /purple leopard print and uneven hem/i);

  const greenPrompt = catalogPrompt({ label: "pale mint green shirt", observed: "mint fabric", unknowns: [] });
  assert.match(greenPrompt, /chroma magenta \(#FF00FF\)/i);

  const pursePrompt = catalogPrompt({ label: "black shoulder bag", category: "accessories", subcategory: "purse", color: "Black", observed: "silver buckle", unknowns: [] });
  assert.match(pursePrompt, /standalone product/i);
  assert.match(pursePrompt, /handle, strap, closure/i);
  assert.doesNotMatch(pursePrompt, /ghost mannequin/i);

  const jewelryPrompt = catalogPrompt({ label: "gold pendant necklace", category: "accessories", subcategory: "jewelry", color: "Gold", observed: "round pendant", unknowns: [] });
  assert.match(jewelryPrompt, /complete jewelry item/i);
  assert.match(jewelryPrompt, /chain shape/i);
  assert.doesNotMatch(jewelryPrompt, /ghost mannequin/i);
});

test("catalog image generation is serialized so photos cannot claim each other's artifact", async () => {
  const queue = new SerialQueue();
  let active = 0; let maximumActive = 0; const completed = [];
  const operation = (photo) => queue.run(async () => {
    active += 1; maximumActive = Math.max(maximumActive, active);
    await new Promise(resolve => setTimeout(resolve, photo === "first" ? 12 : 1));
    completed.push(photo); active -= 1;
    return photo;
  });
  const results = await Promise.all([operation("first"), operation("second"), operation("third")]);
  assert.deepEqual(results, ["first", "second", "third"]);
  assert.deepEqual(completed, ["first", "second", "third"]);
  assert.equal(maximumActive, 1);
});

test("catalog edits are narrowly scoped and retain transparency", () => {
  const prompt = catalogEditPrompt("remove the loose thread at the hem");
  assert.match(prompt, /change only what the request explicitly names/i);
  assert.match(prompt, /transparent alpha background/i);
  assert.match(prompt, /remove the loose thread at the hem/i);
});

test("a hung Codex turn times out instead of blocking every import", async () => {
  await assert.rejects(
    withAbortTimeout(5, "analysis timed out", signal => new Promise((_, reject) => {
      signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
    })),
    /analysis timed out/
  );
});

test("a parent cancellation aborts an in-flight operation", async () => {
  const parent = new AbortController();
  const operation = withAbortTimeout(1000, "timed out", signal => new Promise((_, reject) => {
    signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
  }), parent.signal);
  parent.abort(new Error("import cancelled"));
  await assert.rejects(operation, /import cancelled/);
});

test("a job actively polled by the phone jumps ahead of abandoned backlog", async () => {
  const started = []; let releaseFirst;
  const firstGate = new Promise(resolve => { releaseFirst = resolve; });
  const queue = new PriorityQueue(async id => {
    started.push(id);
    if (id === "already-processing") await firstGate;
  });
  queue.enqueue("already-processing", 0);
  await new Promise(resolve => setTimeout(resolve, 1));
  queue.enqueue("old-backlog", 0);
  queue.enqueue("phone-is-waiting", 100);
  releaseFirst();
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.deepEqual(started, ["already-processing", "phone-is-waiting", "old-backlog"]);
});

test("analysis queue runs two isolated worker slots without reusing an active slot", async () => {
  let active = 0; let maximumActive = 0;
  const activeSlots = new Set();
  const seenSlots = new Set();
  const queue = new PriorityQueue(async (_id, slot) => {
    assert.equal(activeSlots.has(slot), false);
    activeSlots.add(slot); seenSlots.add(slot);
    active += 1; maximumActive = Math.max(maximumActive, active);
    await new Promise(resolve => setTimeout(resolve, 8));
    active -= 1; activeSlots.delete(slot);
  }, 2);
  queue.enqueue("one"); queue.enqueue("two"); queue.enqueue("three"); queue.enqueue("four");
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(maximumActive, 2);
  assert.deepEqual([...seenSlots].sort(), [0, 1]);
});

test("priority queue exposes a one-based waiting position", async () => {
  let releaseFirst;
  const firstGate = new Promise(resolve => { releaseFirst = resolve; });
  const queue = new PriorityQueue(async id => { if (id === "active") await firstGate; });
  queue.enqueue("active", 0);
  await new Promise(resolve => setTimeout(resolve, 1));
  queue.enqueue("first-waiting", 10);
  queue.enqueue("second-waiting", 0);
  assert.equal(queue.position("first-waiting"), 1);
  assert.equal(queue.position("second-waiting"), 2);
  releaseFirst();
});
