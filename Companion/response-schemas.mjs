export function outfitSchema(validIDs, min = 3, max = 5, layeringIDs = validIDs) {
  return { type: "object", additionalProperties: false, required: ["outfits"], properties: {
    outfits: { type: "array", minItems: min, maxItems: max, items: {
      type: "object", additionalProperties: false, required: ["title", "rationale", "garmentIDs", "layering"], properties: {
        title: { type: "string" }, rationale: { type: "string" },
        // Codex structured outputs do not accept JSON Schema's `uniqueItems`.
        // Duplicate IDs are rejected after decoding instead.
        garmentIDs: { type: "array", minItems: 2, maxItems: 5, items: { type: "string", enum: validIDs } },
        layering: { type: "array", maxItems: 2, items: {
          type: "object", additionalProperties: false, required: ["garmentID", "placement"], properties: {
            garmentID: { type: "string", enum: layeringIDs },
            placement: { type: "string", enum: ["under", "main", "over"] }
          }
        }}
      }
    }}
  }};
}

export function assessmentSchema(validIDs) {
  return { type: "object", additionalProperties: false, required: ["verdict", "summary", "outfits"], properties: {
    verdict: { type: "string", enum: ["buy", "maybe", "skip"] }, summary: { type: "string" },
    outfits: outfitSchema(validIDs, 3, 5, [...validIDs, "__candidate__"]).properties.outfits
  }};
}

export function outfitSelectionSchema(candidateIDs) {
  return { type: "object", additionalProperties: false, required: ["selections"], properties: {
    selections: { type: "array", minItems: 3, maxItems: 3, items: {
      type: "object", additionalProperties: false, required: ["candidateID", "title", "rationale"], properties: {
        candidateID: { type: "string", enum: candidateIDs },
        title: { type: "string" }, rationale: { type: "string" }
      }
    }}
  }};
}

export function itemRecommendationSchema(candidateIDs) {
  return { type: "object", additionalProperties: false, required: ["garmentID", "rationale"], properties: {
    garmentID: { type: "string", enum: candidateIDs },
    rationale: { type: "string" }
  }};
}
