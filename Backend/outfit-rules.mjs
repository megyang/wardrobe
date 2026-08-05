const TORSO_CATEGORIES = new Set(["tops", "dresses"]);
const CANDIDATE_ID = "__candidate__";

function candidateRecord(candidate) {
  return candidate ? { ...candidate, id: CANDIDATE_ID } : null;
}

function hasExplicitTorsoLayer(torsoItems, layering) {
  if (!Array.isArray(layering) || layering.length !== 2) return false;
  const byID = new Map(torsoItems.map(item => [item.id, item]));
  const underStep = layering.find(step => step.placement === "under");
  const outerStep = layering.find(step => ["main", "over"].includes(step.placement));
  if (!underStep || !outerStep || underStep.garmentID === outerStep.garmentID) return false;
  return Boolean(byID.get(underStep.garmentID) && byID.get(outerStep.garmentID));
}

export function hasValidOutfitComposition(garmentIDs, wardrobe, candidate = null, layering = []) {
  if (!Array.isArray(garmentIDs) || new Set(garmentIDs).size !== garmentIDs.length) return false;
  const wardrobeByID = new Map(wardrobe.map(item => [item.id, item]));
  const candidateItem = candidateRecord(candidate);
  const counts = new Map(candidateItem ? [[candidateItem.category, 1]] : []);
  const items = candidateItem ? [candidateItem] : [];
  for (const id of garmentIDs) {
    const item = wardrobeByID.get(id);
    if (!item) return false;
    items.push(item);
    counts.set(item.category, (counts.get(item.category) || 0) + 1);
  }

  if ((counts.get("bottoms") || 0) > 1 || (counts.get("dresses") || 0) > 1 || (counts.get("tops") || 0) > 2) return false;
  const torsoItems = items.filter(item => TORSO_CATEGORIES.has(item.category));
  if (torsoItems.length > 2) return false;
  if (torsoItems.length < 2) return layering.length === 0;

  const plannedIDs = layering.map(step => step.garmentID);
  return new Set(plannedIDs).size === 2 && torsoItems.every(item => plannedIDs.includes(item.id)) &&
    hasExplicitTorsoLayer(torsoItems, layering);
}

export { CANDIDATE_ID };
