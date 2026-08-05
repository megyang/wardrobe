import { SUBCATEGORIES } from "./category-taxonomy.mjs";

export function recommendationTarget(value) {
  const category = String(value?.category || "");
  const subcategory = value?.subcategory == null ? null : String(value.subcategory);
  if (!category && !subcategory) return { category: null, subcategory: null };
  if (!Object.hasOwn(SUBCATEGORIES, category)) throw new Error("Choose a valid wardrobe category.");
  if (subcategory && !SUBCATEGORIES[category].includes(subcategory)) throw new Error("Choose a subcategory within the selected category.");
  return { category, subcategory };
}

export function eligibleRecommendationItems(wardrobe, selectedIDs, targetValue) {
  const target = recommendationTarget(targetValue);
  const selected = new Set(Array.isArray(selectedIDs) ? selectedIDs : []);
  return (Array.isArray(wardrobe) ? wardrobe : []).filter(item =>
    item?.id && !selected.has(item.id) && (!target.category || item.category === target.category) &&
    (!target.subcategory || item.subcategory === target.subcategory)
  );
}
