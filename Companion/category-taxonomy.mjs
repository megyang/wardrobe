export const SUBCATEGORIES = {
  tops: ["long_sleeve", "tank_top", "t_shirt", "sleeveless", "blouse"],
  bottoms: ["shorts", "skirt", "pants"],
  outerwear: ["coverup", "sweater", "jacket", "coat"],
  dresses: [],
  shoes: [],
  accessories: ["tights", "hat", "misc"]
};

export const SUBCATEGORY_VALUES = ["none", ...new Set(Object.values(SUBCATEGORIES).flat())];

export function normalizeSubcategory(category, subcategory) {
  return SUBCATEGORIES[category]?.includes(subcategory) ? subcategory : null;
}
