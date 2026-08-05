export const STYLE_ANALYSIS_VERSION = "2";

const score = { type: "number", minimum: 0, maximum: 1 };
const shortStrings = { type: "array", maxItems: 6, items: { type: "string" } };

export const inspirationSchema = {
  type: "object",
  additionalProperties: false,
  required: ["summary", "aesthetics", "palette", "silhouettes", "layering", "details", "occasions", "outfitFormula", "proportions", "focalPoints", "stylingRules", "vector"],
  properties: {
    summary: { type: "string" },
    aesthetics: shortStrings,
    palette: shortStrings,
    silhouettes: shortStrings,
    layering: shortStrings,
    details: shortStrings,
    occasions: shortStrings,
    outfitFormula: { type: "array", maxItems: 8, items: { type: "string" } },
    proportions: shortStrings,
    focalPoints: { type: "array", maxItems: 4, items: { type: "string" } },
    stylingRules: shortStrings,
    vector: {
      type: "object",
      additionalProperties: false,
      required: ["minimal", "maximal", "relaxed", "tailored", "romantic", "edgy", "sporty", "vintage", "classic", "experimental", "layered", "colorful"],
      properties: {
        minimal: score, maximal: score, relaxed: score, tailored: score,
        romantic: score, edgy: score, sporty: score, vintage: score,
        classic: score, experimental: score, layered: score, colorful: score
      }
    }
  }
};

export function inspirationPrompt() {
  return [
    "Analyze this outfit as a fashion inspiration reference. Focus on styling choices, not the person's identity, body, attractiveness, brand, price, or setting.",
    "Describe visible silhouette, proportions, palette, contrast, garment interaction, layering, textures, styling details, formality, and likely occasions. Do not invent unseen materials or construction.",
    "Preserve the relationships that make the outfit work. outfitFormula lists generic garment roles from base to finishing pieces. proportions records balance and length relationships. focalPoints names what visually leads. stylingRules states reusable if/then principles from this specific look.",
    "Return concise reusable preference traits. Vector scores run from 0 (not represented) to 1 (strongly represented). Opposing traits may both be low or moderately present; do not force a binary choice.",
    "This analysis will be cached and reused so another stylist can match the user's wardrobe to the look's principles without copying exact garments."
  ].join("\n\n");
}
