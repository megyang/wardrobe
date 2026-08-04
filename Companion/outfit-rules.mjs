const TORSO_CATEGORIES = new Set(["tops", "dresses"]);
const CANDIDATE_ID = "__candidate__";

export function hasValidOutfitComposition(garmentIDs, wardrobe, candidateCategory = null, layering = []) {
  if (!Array.isArray(garmentIDs) || new Set(garmentIDs).size !== garmentIDs.length) return false;
  const categories = new Map(wardrobe.map(item => [item.id, item.category]));
  const counts = new Map(candidateCategory ? [[candidateCategory, 1]] : []);
  const torsoIDs = candidateCategory && TORSO_CATEGORIES.has(candidateCategory) ? [CANDIDATE_ID] : [];
  for (const id of garmentIDs) {
    const category = categories.get(id);
    if (!category) return false;
    counts.set(category, (counts.get(category) || 0) + 1);
    if (TORSO_CATEGORIES.has(category)) torsoIDs.push(id);
  }

  if ((counts.get("bottoms") || 0) > 1 || (counts.get("dresses") || 0) > 1 || (counts.get("tops") || 0) > 2) return false;
  // Keep layering legible: either two tops, or a top with a dress, but never a three-piece torso stack.
  if (torsoIDs.length > 2) return false;
  if (torsoIDs.length < 2) return layering.length === 0;

  if (!Array.isArray(layering) || layering.length !== 2) return false;
  const plannedIDs = layering.map(step => step.garmentID);
  if (new Set(plannedIDs).size !== 2 || !torsoIDs.every(id => plannedIDs.includes(id))) return false;
  const placements = new Set(layering.map(step => step.placement));
  if (!placements.has("under") || (!placements.has("main") && !placements.has("over"))) return false;
  return true;
}

export { CANDIDATE_ID };
