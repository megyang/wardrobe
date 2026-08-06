const CORE_CATEGORIES = new Set(["tops", "bottoms", "dresses"]);

export function outfitSimilarityKey(garmentIDs, wardrobe) {
  const categories = new Map((wardrobe || []).map(item => [String(item.id).toLowerCase(), item.category]));
  const all = [...new Set((garmentIDs || []).map(id => String(id).toLowerCase()))];
  const core = all.filter(id => CORE_CATEGORIES.has(categories.get(id)));
  return (core.length ? core : all).sort().join("|");
}

export function representedOutfitKeys(outfits, wardrobe) {
  return new Set((outfits || []).map(outfit => outfitSimilarityKey(outfit.garmentIDs, wardrobe)).filter(Boolean));
}
