const SCARF_METHOD = /\b(?:tie|tied|knot|knotted|drape|draped|wrap|wrapped|loop|looped|wear|worn|style|styled)\b|\bas (?:a )?(?:headscarf|headband|hair tie|belt|bag tie)\b/i;

function isScarf(item) {
  return item?.subcategory === "scarf" || /\bscarf\b/i.test(item?.label || "");
}

function stylingSentence(value) {
  return String(value || "")
    .split(/(?<=[.!?])\s+/)
    .find(sentence => /\bscarf\b/i.test(sentence) && SCARF_METHOD.test(sentence));
}

export function ensureScarfStylingRationale(outfit, wardrobe, finalRationale) {
  const byID = new Map(wardrobe.map(item => [item.id, item]));
  const scarf = (outfit.garmentIDs || []).map(id => byID.get(id)).find(isScarf);
  const rationale = String(finalRationale || outfit.rationale || "").trim();
  if (!scarf) return rationale;
  if (stylingSentence(rationale)) return rationale;

  const candidateInstruction = stylingSentence(outfit.rationale);
  if (candidateInstruction) {
    return [rationale, candidateInstruction].filter(Boolean).join(" ");
  }

  const label = String(scarf.label || "scarf").trim();
  const instruction = `Scarf styling: tie the ${label} loosely at the neck and let the ends drape.`;
  return [rationale, instruction].filter(Boolean).join(" ");
}
