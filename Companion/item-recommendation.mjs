const TARGETS = new Map([
  ["accessories", { category: "accessories", subcategory: null }],
  ["misc", { category: "accessories", subcategory: "misc" }],
  ["tights", { category: "accessories", subcategory: "tights" }],
  ["bottoms", { category: "bottoms", subcategory: null }],
  ["hats", { category: "accessories", subcategory: "hat" }],
  ["coats", { category: "outerwear", subcategory: "coat" }]
]);

export function recommendationTarget(value) {
  const target = TARGETS.get(String(value || ""));
  if (!target) throw new Error("Choose accessories, misc, tights, bottoms, hats, or coats.");
  return target;
}

export function eligibleRecommendationItems(wardrobe, selectedIDs, targetValue) {
  const target = recommendationTarget(targetValue);
  const selected = new Set(Array.isArray(selectedIDs) ? selectedIDs : []);
  return (Array.isArray(wardrobe) ? wardrobe : []).filter(item =>
    item?.id && !selected.has(item.id) && item.category === target.category &&
    (!target.subcategory || item.subcategory === target.subcategory)
  );
}
