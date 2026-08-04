export function catalogPrompt(item) {
  return [
    `Create a faithful ecommerce catalog cutout of ONLY the exact ${item.label} shown in the source photo.`,
    "This is a garment-isolation task, not a fashion visualization or redesign.",
    "Show one complete empty garment, front-facing and naturally laid out as a clean product packshot.",
    "Use a portrait 4:5 transparent canvas with a true alpha channel. Center the garment and make it fill roughly 80% of the canvas while keeping every edge fully visible.",
    "Remove the person, skin, body shape, mannequin, hanger, other clothing, props, room, floor, text, labels, borders, and decorative shadows.",
    `Preserve these source-supported details exactly: ${item.observed}.`,
    `Unknown details: ${(item.unknowns || []).join(", ") || "none"}.`,
    "Preserve the visible silhouette, proportions, hemline, neckline, sleeves, color, pattern placement, texture, and construction. Prefer a neutral omission over guessing.",
    "Do not beautify, restyle, simplify, crop, mirror, recolor, lengthen, shorten, symmetrize, or add unsupported logos, text, pockets, seams, fasteners, hardware, trim, patterns, or accessories.",
    "Output exactly one tightly cropped catalog cutout with a transparent background, no backdrop color, no caption, and no surrounding scene."
  ].join(" ");
}

export function catalogEditPrompt(instruction) {
  return [
    "Make one restrained edit to this exact catalog garment cutout.",
    `Requested edit: ${instruction}.`,
    "Change only what the request explicitly names. Preserve the garment's identity, silhouette, proportions, color, material, texture, pattern, construction, and every unrelated visible detail.",
    "Do not add a person, body, mannequin, hanger, styling, accessories, labels, logos, text, scenery, floor, shadows, or new garment details.",
    "Keep the complete garment visible and centered. Return exactly one tightly cropped PNG-style cutout with a true transparent alpha background and no backdrop color."
  ].join(" ");
}
