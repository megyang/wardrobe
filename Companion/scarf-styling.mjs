const SCARF_METHOD = /\b(?:tie|tied|knot|knotted|drape|draped|wrap|wrapped|loop|looped|wear|worn|style|styled)\b|\bas (?:a )?(?:headscarf|headband|hair tie|belt|bag tie)\b/i;
const COPIES_PHOTO = /\b(?:as shown|as pictured|as photographed|same way|current shape|existing shape)\b/i;

function isScarf(item) {
  return item?.subcategory === "scarf" || /\bscarf\b/i.test(item?.label || "");
}

function stylingSentences(value) {
  return String(value || "")
    .split(/(?<=[.!?])\s+/)
    .filter(sentence =>
      ((/\bscarf\b/i.test(sentence) && SCARF_METHOD.test(sentence)) ||
        (/\b(?:another way|alternative)\s*:/i.test(sentence) && SCARF_METHOD.test(sentence))) &&
      !COPIES_PHOTO.test(sentence)
    );
}

function shortText(value, maximumWords = 14) {
  const words = String(value || "").replace(/\s+/g, " ").trim().split(" ").filter(Boolean);
  const text = words.slice(0, maximumWords).join(" ").replace(/[.,;:!?]+$/, "");
  return text ? `${text}.` : "";
}

function instructionText(value) {
  return String(value || "")
    .replace(/^(?:how to wear (?:the )?scarf|scarf styling|another way|alternative)\s*:\s*/i, "")
    .replace(/^wear (?:the )?scarf\s+/i, "")
    .replace(/^as\s+(?:a\s+)?/i, "")
    .trim();
}

function alternativeInstruction(primary, scarf) {
  const evidence = [scarf.label, scarf.description, scarf.observed].filter(Boolean).join(" ");
  const isLongAndNarrow = /\b(?:long|skinny|thin|narrow|slim)\b/i.test(evidence);
  if (/\b(?:belt|belt loops|waist)\b/i.test(primary)) {
    return "Knot it at the neck; leave the ends long and uneven.";
  }
  if (/\b(?:hair|ponytail|headband|headscarf)\b/i.test(primary)) {
    return isLongAndNarrow
      ? "Thread it through two belt loops as a soft belt."
      : "Make a small side knot at the neck.";
  }
  return isLongAndNarrow
    ? "Use it as a low-ponytail ribbon."
    : "Tie a small side knot at the neck.";
}

export function ensureScarfStylingRationale(outfit, wardrobe, finalRationale) {
  const byID = new Map(wardrobe.map(item => [item.id, item]));
  const scarf = (outfit.garmentIDs || []).map(id => byID.get(id)).find(isScarf);
  const rationale = String(finalRationale || outfit.rationale || "").trim();
  if (!scarf) return rationale;
  const finalInstructions = stylingSentences(rationale);
  const candidateInstructions = stylingSentences(outfit.rationale);
  const primary = finalInstructions[0] || candidateInstructions[0] ||
    `Knot the ${String(scarf.label || "scarf").trim()} at the neck; leave the ends uneven.`;
  const secondary = candidateInstructions.find(sentence => sentence !== primary) || alternativeInstruction(primary, scarf);
  const general = String(rationale)
    .split(/(?<=[.!?])\s+/)
    .find(sentence => !stylingSentences(sentence).length && !COPIES_PHOTO.test(sentence) && !/\b(?:another way|alternative)\s*:/i.test(sentence));
  return [
    shortText(general, 16),
    `Scarf: ${shortText(instructionText(primary), 12)}`,
    `Alternative: ${shortText(instructionText(finalInstructions[1] || secondary), 12)}`
  ].filter(Boolean).join(" ");
}
