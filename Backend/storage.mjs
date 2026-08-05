import { createClient } from "@supabase/supabase-js";
import crypto from "node:crypto";
import { httpError } from "./auth.mjs";

export const ASSET_BUCKET = "wearwell-assets";

export function createStorage(config) {
  const client = createClient(config.supabaseURL, config.supabaseServiceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  return {
    path(ownerID, assetID, extension = "bin") { return `${ownerID}/${assetID}/original.${extension.replace(/[^a-z0-9]/gi, "").toLowerCase() || "bin"}`; },
    async signedUpload(path) {
      const { data, error } = await client.storage.from(ASSET_BUCKET).createSignedUploadUrl(path);
      if (error) throw error; return data;
    },
    async signedDownload(path, seconds = 300) {
      const { data, error } = await client.storage.from(ASSET_BUCKET).createSignedUrl(path, seconds);
      if (error) throw error; return data.signedUrl;
    },
    async download(path) {
      const { data, error } = await client.storage.from(ASSET_BUCKET).download(path);
      if (error) throw error; return Buffer.from(await data.arrayBuffer());
    },
    async upload(path, bytes, contentType) {
      const { error } = await client.storage.from(ASSET_BUCKET).upload(path, bytes, { contentType, upsert: false });
      if (error) throw error;
    },
    async remove(paths) { if (!paths.length) return; const { error } = await client.storage.from(ASSET_BUCKET).remove(paths); if (error) throw error; }
  };
}

export function validateAssetMetadata({ mimeType, byteCount, sha256 }) {
  if (!/^image\/(jpeg|png|webp|heic)$/i.test(String(mimeType || ""))) throw httpError(400, "Unsupported image type.");
  if (!Number.isSafeInteger(byteCount) || byteCount < 1 || byteCount > 18 * 1024 * 1024) throw httpError(400, "Image must be 18 MB or smaller.");
  if (!/^[0-9a-f]{64}$/i.test(String(sha256 || ""))) throw httpError(400, "A SHA-256 checksum is required.");
}

export function sha256(bytes) { return crypto.createHash("sha256").update(bytes).digest("hex"); }
