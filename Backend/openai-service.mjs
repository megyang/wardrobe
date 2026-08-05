import OpenAI, { toFile } from "openai";
import crypto from "node:crypto";

export function createOpenAIService(config) {
  const client = new OpenAI({ apiKey: config.openAIKey });

  return {
    async structured({ name, prompt, images = [], schema, userID, signal }) {
      const started = Date.now();
      const content = [{ type: "input_text", text: prompt }];
      for (const image of images) content.push({ type: "input_image", image_url: `data:${image.mimeType};base64,${image.bytes.toString("base64")}`, detail: "auto" });
      const response = await client.responses.create({
        model: config.textModel,
        reasoning: { effort: "medium" },
        service_tier: "default",
        store: false,
        safety_identifier: safetyIdentifier(userID),
        input: [{ role: "user", content }],
        text: { format: { type: "json_schema", name, strict: true, schema } }
      }, { signal });
      return {
        value: JSON.parse(response.output_text),
        usage: normalizeUsage(response.usage),
        latencyMs: Date.now() - started,
        model: response.model || config.textModel
      };
    },

    async editImage({ prompt, images, userID: _userID, signal }) {
      const started = Date.now();
      const files = await Promise.all(images.map((image, index) => toFile(image.bytes, `reference-${index + 1}.${extension(image.mimeType)}`, { type: image.mimeType })));
      const response = await client.images.edit({
        model: config.imageModel,
        image: files,
        prompt,
        size: "1024x1024",
        quality: "high",
        output_format: "png",
        background: "transparent"
      }, { signal });
      const encoded = response.data?.[0]?.b64_json;
      if (!encoded) throw new Error("OpenAI did not return an image.");
      return { bytes: Buffer.from(encoded, "base64"), usage: { imageCalls: 1 }, latencyMs: Date.now() - started, model: config.imageModel };
    }
  };
}

function normalizeUsage(usage) {
  return {
    inputTokens: usage?.input_tokens || 0,
    outputTokens: usage?.output_tokens || 0,
    totalTokens: usage?.total_tokens || 0,
    imageCalls: 0
  };
}

function safetyIdentifier(userID) { return crypto.createHash("sha256").update(`wearwell:${userID}`).digest("hex").slice(0, 64); }
function extension(mimeType) { return mimeType === "image/png" ? "png" : mimeType === "image/webp" ? "webp" : mimeType === "image/heic" ? "heic" : "jpg"; }
