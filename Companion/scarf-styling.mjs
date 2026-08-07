const SCARF_METHOD = /\b(?:tie|tied|knot|knotted|drape|draped|wrap|wrapped|loop|looped|wear|worn|style|styled)\b|\bas (?:a )?(?:headscarf|headband|hair tie|belt|bag tie)\b/i;
const COPIES_PHOTO = /\b(?:as shown|as pictured|as photographed|same way|current shape|existing shape)\b/i;

function isScarf(item) {
  return item?.subcategory === "scarf" || /\bscarf\b/i.test(item?.label || "");
}

function stylingSentences(value) {
  return String(value || "")
    .split(/(?<=[.!?])\s+/)
    .filter(sentence => /\bscarf\b/i.test(sentence) && SCARF_METHOD.test(sentence) && !COPIES_PHOTO.test(sentence));
}

function alternativeInstruction(primary, scarf) {
  const evidence = [scarf.label, scarf.description, scarf.observed].filter(Boolean).join(" ");
  const isLongAndNarrow = /\b(?:long|skinny|thin|narrow|slim)\b/i.test(evidence);
  if (/\b(?:belt|belt loops|waist)\b/i.test(primary)) {
    return "Another way: knot it close at the neck and leave the two ends long and uneven.";
  }
  if (/\b(?:hair|ponytail|headband|headscarf)\b/i.test(primary)) {
    return isLongAndNarrow
      ? "Another way: thread it through two belt loops and tie it slightly off-center as a soft belt."
      : "Another way: make a small side knot at the neck and let the ends fall over the top.";
  }
  return isLongAndNarrow
    ? "Another way: use it as a ribbon around a low ponytail, leaving the ends loose."
    : "Another way: tie a small side knot at the neck instead of copying the photographed drape.";
}

export function ensureScarfStylingRationale(outfit, wardrobe, finalRationale) {
  const byID = new Map(wardrobe.map(item => [item.id, item]));
  const scarf = (outfit.garmentIDs || []).map(id => byID.get(id)).find(isScarf);
  const rationale = String(finalRationale || outfit.rationale || "").trim();
  if (!scarf) return rationale;
  const finalInstructions = stylingSentences(rationale);
  if (finalInstructions.length >= 2 && /\b(?:another|alternative|other) (?:way|option)\b/i.test(rationale)) return rationale;

  const candidateInstructions = stylingSentences(outfit.rationale);
  const primary = finalInstructions[0] || candidateInstructions[0] ||
    `How to wear the scarf: knot the ${String(scarf.label || "scarf").trim()} loosely at the neck and leave the ends long.`;
  const secondary = candidateInstructions.find(sentence => sentence !== primary) || alternativeInstruction(primary, scarf);
  const additions = [];
  if (!finalInstructions.length) additions.push(primary);
  additions.push(secondary);
  return [rationale, ...additions].filter(Boolean).join(" ");
}
