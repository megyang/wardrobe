export function catalogPrompt(item) {
  const description = `${item.label || ""} ${item.observed || ""}`.toLowerCase();
  const greenGarment = /\b(green|mint|teal|turquoise|olive|lime|chartreuse|emerald|aqua)\b/.test(description);
  const backdrop = greenGarment ? "vivid chroma magenta (#FF00FF)" : "vivid chroma green (#00FF00)";
  return [
    `Create a faithful ecommerce catalog cutout of ONLY the exact ${item.label} shown in the source photo.`,
    "This is a garment-isolation task, not a fashion visualization or redesign.",
    "Show one complete empty garment, front-facing, with natural three-dimensional drape and volume as if it were being worn by an invisible ghost mannequin. No person, skin, mannequin, hanger, or body may be visible.",
    "Do not copy a laid-flat pose, floor arrangement, or collapsed wrinkles from a flat-lay source. When both worn and flat-lay references are provided, use the worn reference for silhouette, proportions, and drape, and use the flat-lay reference only to recover unobstructed construction details.",
    `Use a portrait 4:5 canvas filled edge-to-edge with one perfectly flat ${backdrop} background. Center the garment and make it fill roughly 80% of the canvas while keeping every edge fully visible. The same backdrop color must remain visible through every opening in lace, crochet, mesh, eyelets, straps, and cutwork.`,
    "Remove the person, skin, body shape, mannequin, hanger, other clothing, props, room, floor, text, labels, borders, and decorative shadows.",
    `Preserve these source-supported details exactly: ${item.observed}.`,
    `The garment's base color is ${item.color || "the source-supported color"}. Preserve its actual hue and saturation; do not bleach, whiten, mute, or recolor it.`,
    `Unknown details: ${(item.unknowns || []).join(", ") || "none"}.`,
    "Preserve the visible silhouette, proportions, hemline, neckline, sleeves, color, pattern placement, texture, and construction. Prefer a neutral omission over guessing.",
    "Do not beautify, restyle, simplify, crop, mirror, recolor, lengthen, shorten, symmetrize, or add unsupported logos, text, pockets, seams, fasteners, hardware, trim, patterns, or accessories.",
    "Output exactly one catalog product image on that single solid chroma background. Do not draw transparency, a checkerboard, pixel grid, gradient, shadow, floor, caption, border, or surrounding scene. The app will remove the chroma background and convert it to true transparency."
  ].join(" ");
}

export function catalogEditPrompt(instruction) {
  return [
    "Make one restrained edit to this exact catalog garment cutout.",
    `Requested edit: ${instruction}.`,
    "Change only what the request explicitly names. Preserve the garment's identity, silhouette, proportions, color, material, texture, pattern, construction, and every unrelated visible detail.",
    "Do not add a person, body, mannequin, hanger, styling, accessories, labels, logos, text, scenery, floor, shadows, or new garment details.",
    "Keep the complete garment visible and centered. Return exactly one tightly cropped PNG-style cutout with a true transparent alpha background, including through lace or mesh openings, and no green screen, checkerboard, pixel grid, or backdrop color."
  ].join(" ");
}
