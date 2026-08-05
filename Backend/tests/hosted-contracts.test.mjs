import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { loadConfig } from "../config.mjs";
import { httpError } from "../auth.mjs";
import { validateAssetMetadata } from "../storage.mjs";

const env = {
  DATABASE_URL: "postgresql://localhost/wearwell",
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "test-only",
  OPENAI_API_KEY: "test-only"
};

test("hosted configuration fails closed when server secrets are absent", () => {
  assert.throws(() => loadConfig({}), /DATABASE_URL/);
  const config = loadConfig(env);
  assert.equal(config.textModel, "gpt-5.6-luna");
  assert.equal(config.imageModel, "gpt-image-2");
});

test("asset declarations enforce image type, size, and checksum", () => {
  assert.doesNotThrow(() => validateAssetMetadata({ mimeType: "image/jpeg", byteCount: 10, sha256: "a".repeat(64) }));
  assert.throws(() => validateAssetMetadata({ mimeType: "text/plain", byteCount: 10, sha256: "a".repeat(64) }));
  assert.throws(() => validateAssetMetadata({ mimeType: "image/png", byteCount: 19 * 1024 * 1024, sha256: "a".repeat(64) }));
  assert.throws(() => validateAssetMetadata({ mimeType: "image/png", byteCount: 10, sha256: "nope" }));
});

test("HTTP errors keep status and stable machine code", () => {
  const error = httpError(409, "Sync first.", "revision_conflict");
  assert.equal(error.status, 409); assert.equal(error.code, "revision_conflict");
});

test("database migration enables RLS and durable leased jobs", () => {
  const migration = fs.readFileSync(new URL("../supabase/migrations/0001_hosted_wearwell.sql", import.meta.url), "utf8");
  for (const marker of ["enable row level security", "create_job_with_quota", "for update skip locked", "claim_job", "sync_changes", "purge_account"]) assert.match(migration.toLowerCase(), new RegExp(marker.replaceAll(" ", "\\s+")));
});

test("public server does not contain local pairing or Codex login paths", () => {
  const server = fs.readFileSync(new URL("../server.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(server, /pairing|bonjour|auth\.json|codex login/i);
  assert.match(server, /idempotency-key/i);
});
