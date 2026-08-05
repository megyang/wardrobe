import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { loadConfig } from "../config.mjs";
import { httpError } from "../auth.mjs";
import { createStorage, validateAssetMetadata } from "../storage.mjs";

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

test("private asset paths are immutable and owner scoped", () => {
  const storage = createStorage({ supabaseURL: env.SUPABASE_URL, supabaseServiceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY });
  assert.equal(storage.path("owner-a", "asset-b", "JpG"), "owner-a/asset-b/original.jpg");
  assert.equal(storage.path("owner-a", "asset-b", "../../png"), "owner-a/asset-b/original.png");
});

test("HTTP errors keep status and stable machine code", () => {
  const error = httpError(409, "Sync first.", "revision_conflict");
  assert.equal(error.status, 409); assert.equal(error.code, "revision_conflict");
});

test("database migration enables RLS and durable leased jobs", () => {
  const migration = fs.readFileSync(new URL("../supabase/migrations/0001_hosted_wearwell.sql", import.meta.url), "utf8");
  for (const marker of ["enable row level security", "create_job_with_quota", "for update skip locked", "claim_job", "sync_changes", "purge_account", "asset_references", "outfit_ratings"]) assert.match(migration.toLowerCase(), new RegExp(marker.replaceAll(" ", "\\s+")));
  for (const limit of ["default 25", "default 50", "default 10", "default 1073741824"]) assert.match(migration.toLowerCase(), new RegExp(limit.replace(" ", "\\s+")));
  assert.match(migration, /owner_id=auth\.uid\(\)/);
});

test("terminal jobs scrub working requests and abandoned assets are purged", () => {
  const worker = fs.readFileSync(new URL("../worker.mjs", import.meta.url), "utf8");
  const server = fs.readFileSync(new URL("../server.mjs", import.meta.url), "utf8");
  assert.match(worker, /request=jsonb_build_object\('completed',true\)/);
  assert.match(worker, /purgeUnreferencedAssets/);
  assert.match(server, /request=jsonb_build_object\('cancelled',true\)/);
});

test("public server does not contain local pairing or Codex login paths", () => {
  const server = fs.readFileSync(new URL("../server.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(server, /pairing|bonjour|auth\.json|codex login/i);
  assert.match(server, /idempotency-key/i);
});

test("OpenAI calls are stateless, schema constrained, and use the standard tier", () => {
  const source = fs.readFileSync(new URL("../openai-service.mjs", import.meta.url), "utf8");
  assert.match(source, /store:\s*false/);
  assert.match(source, /service_tier:\s*"default"/);
  assert.match(source, /reasoning:\s*\{\s*effort:\s*"medium"/);
  assert.match(source, /safety_identifier:\s*safetyIdentifier/);
  assert.match(source, /type:\s*"json_schema"/);
});
