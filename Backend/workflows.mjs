import { catalogEditPrompt, catalogPrompt } from "./prompts.mjs";
import { SUBCATEGORY_VALUES } from "./category-taxonomy.mjs";
import { assessmentSchema, itemRecommendationSchema, outfitSchema, outfitSelectionSchema } from "./response-schemas.mjs";
import { eligibleRecommendationItems, recommendationTarget } from "./item-recommendation.mjs";
import { inspirationPrompt, inspirationSchema } from "./inspiration.mjs";
import { loadAssets, saveGeneratedAsset } from "./assets.mjs";
import { hasValidOutfitComposition } from "./outfit-rules.mjs";

const inventorySchema = {
  type: "object", additionalProperties: false, required: ["items"], properties: {
    items: { type: "array", minItems: 1, maxItems: 8, items: {
      type: "object", additionalProperties: false,
      required: ["label", "category", "subcategory", "color", "confidence", "description", "observed", "unknowns", "fingerprint"],
      properties: {
        label: { type: "string" }, category: { type: "string", enum: ["tops", "bottoms", "outerwear", "dresses", "shoes", "accessories"] },
        subcategory: { anyOf: [{ type: "string", enum: SUBCATEGORY_VALUES }, { type: "null" }] }, color: { type: "string" }, confidence: { type: "number", minimum: 0, maximum: 1 },
        description: { type: "string" }, observed: { type: "string" }, unknowns: { type: "array", items: { type: "string" } }, fingerprint: { type: "string" }
      }
    }}
  }
};

export function createWorkflows({ db, storage, openai }) {
  return async function run(job, signal) {
    switch (job.kind) {
      case "analyze": return analyze(job, signal);
      case "inspiration": return inspiration(job, signal);
      case "style": return style(job, signal);
      case "assess": return assess(job, signal);
      case "recommend-item": return recommendItem(job, signal);
      case "catalog-edit": return catalogEdit(job, signal);
      case "render": return render(job, signal);
      default: throw new Error(`Unsupported job kind: ${job.kind}`);
    }
  };

  async function analyze(job, signal) {
    const request = job.request; const images = await loadAssets(db, storage, job.owner_id, request.sourceAssetIDs, 12);
    if (!images.length) throw new Error("At least one source image is required.");
    const together = request.sameItem && images.length > 1 ? "These are different views of one garment. Return exactly one item." : "Inventory every deliberately shown clothing item.";
    const prompt = `${together} Exclude the person, background, bags, and jewelry. Describe only visible evidence and list unknown details. Never invent logos, text, pockets, trim, fasteners, materials, or construction. Choose the most specific supported subcategory.`;
    const analysis = await openai.structured({ name: "garment_inventory", prompt, images, schema: inventorySchema, userID: job.owner_id, signal });
    const items = [];
    let imageUsage = { imageCalls: 0 };
    let imageLatencyMs = 0;
    for (const item of analysis.value.items) {
      let catalogAssetID = null;
      if (item.confidence >= 0.45) {
        try {
          const generated = await openai.editImage({ prompt: catalogPrompt(item), images, userID: job.owner_id, signal });
          catalogAssetID = await saveGeneratedAsset(db, storage, job.owner_id, generated.bytes, "catalog");
          imageUsage = combineUsage(imageUsage, generated.usage); imageLatencyMs += generated.latencyMs;
        } catch (error) {
          if (signal?.aborted) throw error;
          // The iOS client preserves the local deterministic cutout path when an image edit is unavailable.
        }
      }
      items.push({ ...item, catalogAssetID, modelVersion: analysis.model });
    }
    return { result: { items }, usage: combineUsage(analysis.usage, imageUsage), model: analysis.model, latencyMs: analysis.latencyMs + imageLatencyMs };
  }

  async function inspiration(job, signal) {
    const images = await loadAssets(db, storage, job.owner_id, [job.request.assetID], 1);
    const response = await openai.structured({ name: "inspiration_analysis", prompt: inspirationPrompt(), images, schema: inspirationSchema, userID: job.owner_id, signal });
    return { result: response.value, usage: response.usage, model: response.model, latencyMs: response.latencyMs };
  }

  async function style(job, signal) {
    const body = job.request; const ids = (body.wardrobe || []).map(item => item.id);
    if (ids.length < 2) throw new Error("Add at least two confirmed garments first.");
    const images = await loadAssets(db, storage, job.owner_id, body.visualAssetIDs, 16);
    const generationPrompt = [
      "Act as Wearwell's wardrobe stylist. Create 10 to 12 genuinely distinct outfits using only supplied owned garment IDs.",
      "Inspect attached owned-garment and inspiration images. Favor the user's demonstrated proportions, silhouette relationships, focal hierarchy, and styling tension over generic color matching.",
      "Use at most two tops, one bottom, one dress, and two torso pieces. For two torso pieces, return explicit under and main/over layering roles. Keep most outfits to two through four pieces.",
      `Direction: ${JSON.stringify({ occasion: body.occasion, weather: body.weather, mood: body.mood, request: body.request, anchorID: body.anchorID })}.`,
      `Style profile and examples: ${JSON.stringify({ styleProfile: body.styleProfile, inspirations: body.inspirationExamples, feedback: body.outfitFeedback, edits: body.outfitEdits, saved: body.savedOutfits })}.`,
      `Owned wardrobe: ${JSON.stringify(body.wardrobe)}.`
    ].join("\n\n");
    const generated = await openai.structured({ name: "outfit_candidates", prompt: generationPrompt, images, schema: outfitSchema(ids, 10, 12), userID: job.owner_id, signal });
    const disliked = new Set((body.outfitFeedback || []).filter(item => item.rating === "disliked").map(item => [...(item.garmentIDs || [])].sort().join("|")));
    const seen = new Set();
    const candidates = generated.value.outfits.filter(item => {
      const key = [...(item.garmentIDs || [])].sort().join("|");
      if (!key || seen.has(key) || disliked.has(key)) return false;
      if (body.anchorID && !(item.garmentIDs || []).includes(body.anchorID)) return false;
      if (!hasValidOutfitComposition(item.garmentIDs,body.wardrobe,null,item.layering || [])) return false;
      seen.add(key); return true;
    }).map((item,index) => ({...item,candidateID:`candidate-${index + 1}`}));
    if (candidates.length < 3) throw new Error("The generated outfits did not pass Wearwell's composition rules.");
    const criticPrompt = `Select exactly three visually coherent, distinct candidates. Do not alter garment IDs or layering. Prefer resemblance to the supplied inspiration and direct feedback over generic safety. Return specific concise titles and rationales.\n\nCandidates: ${JSON.stringify(candidates)}\nWardrobe: ${JSON.stringify(body.wardrobe)}`;
    const ranked = await openai.structured({ name: "outfit_selection", prompt: criticPrompt, images, schema: outfitSelectionSchema(candidates.map(item => item.candidateID)), userID: job.owner_id, signal });
    const byID = new Map(candidates.map(item => [item.candidateID, item]));
    const outfits = ranked.value.selections.map(item => ({ ...byID.get(item.candidateID), title: item.title, rationale: item.rationale })).filter(Boolean);
    if (outfits.length !== 3 || new Set(outfits.map(item => item.candidateID)).size !== 3) throw new Error("The outfit critic returned an invalid selection.");
    return { result: { outfits }, usage: combineUsage(generated.usage, ranked.usage), model: generated.model, latencyMs: generated.latencyMs + ranked.latencyMs };
  }

  async function assess(job, signal) {
    const body = job.request; const ids = (body.wardrobe || []).map(item => item.id);
    const images = await loadAssets(db, storage, job.owner_id, body.visualAssetIDs, 16);
    const prompt = `Assess whether the wishlist candidate adds useful outfit possibilities to this exact wardrobe and style profile. Refer to the candidate with ID __candidate__; use only that ID and supplied owned garment IDs in outfits. Be candid about redundancy and styling limitations.\nCandidate: ${JSON.stringify(body.candidate)}\nWardrobe: ${JSON.stringify(body.wardrobe)}\nStyle evidence: ${JSON.stringify({ profile: body.styleProfile, inspiration: body.inspirationExamples })}`;
    const response = await openai.structured({ name: "purchase_assessment", prompt, images, schema: assessmentSchema(ids), userID: job.owner_id, signal });
    const outfits = (response.value.outfits || []).filter(item => hasValidOutfitComposition(item.garmentIDs,body.wardrobe,body.candidate,item.layering || []));
    if (outfits.length < 3) throw new Error("The purchase outfits did not pass Wearwell's composition rules.");
    return { result: {...response.value,outfits}, usage: response.usage, model: response.model, latencyMs: response.latencyMs };
  }

  async function recommendItem(job, signal) {
    const body = job.request;
    const target = recommendationTarget({ category: body.category, subcategory: body.subcategory });
    const eligible = eligibleRecommendationItems(body.wardrobe, body.selectedGarmentIDs, target);
    if (!eligible.length) throw new Error("No unused wardrobe item matches the selected category.");
    const selected = (body.wardrobe || []).filter(item => (body.selectedGarmentIDs || []).includes(item.id));
    const images = await loadAssets(db, storage, job.owner_id, body.visualAssetIDs, 16);
    const prompt = [
      "Act as Wearwell's wardrobe stylist. Recommend exactly one owned garment to add to the current collage.",
      "Choose only one eligible garment ID. Never invent or suggest purchasing an item.",
      "Inspect the attached garment images and judge silhouette, proportion, palette, texture, print, and the visual role of the new piece. Keep the rationale to one concise sentence.",
      `Requested category: ${JSON.stringify(target)}.`,
      `Current collage: ${JSON.stringify(selected)}.`,
      `Eligible candidates: ${JSON.stringify(eligible)}.`
    ].join("\n\n");
    const response = await openai.structured({
      name: "collage_item_recommendation", prompt, images,
      schema: itemRecommendationSchema(eligible.map(item => item.id)), userID: job.owner_id, signal
    });
    return { result: response.value, usage: response.usage, model: response.model, latencyMs: response.latencyMs };
  }

  async function catalogEdit(job, signal) {
    const images = await loadAssets(db, storage, job.owner_id, [job.request.assetID], 1);
    const generated = await openai.editImage({ prompt: catalogEditPrompt(String(job.request.instruction || "").slice(0, 500)), images, userID: job.owner_id, signal });
    const assetID = await saveGeneratedAsset(db, storage, job.owner_id, generated.bytes, "catalog-edit");
    return { result: { assetID }, usage: generated.usage, model: generated.model, latencyMs: generated.latencyMs };
  }

  async function render(job, signal) {
    const images = await loadAssets(db, storage, job.owner_id, job.request.assetIDs, 12);
    const prompt = `Create one ${job.request.mode || "collage"} wardrobe visualization using only the attached person/reference and garment images. Preserve identity when a person is supplied. Do not invent additional clothing. Generated results are illustrative, not proof of fit.`;
    const generated = await openai.editImage({ prompt, images, userID: job.owner_id, signal });
    const assetID = await saveGeneratedAsset(db, storage, job.owner_id, generated.bytes, "visualization");
    return { result: { assetID }, usage: generated.usage, model: generated.model, latencyMs: generated.latencyMs };
  }
}

function combineUsage(...values) {
  return values.reduce((result, value) => ({ inputTokens: result.inputTokens + (value?.inputTokens || 0), outputTokens: result.outputTokens + (value?.outputTokens || 0), totalTokens: result.totalTokens + (value?.totalTokens || 0), imageCalls: result.imageCalls + (value?.imageCalls || 0) }), { inputTokens: 0, outputTokens: 0, totalTokens: 0, imageCalls: 0 });
}
