import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { BackupStore, decryptBackupBytes, encryptBackupBytes, retainedSnapshotNames, validateBackupManifest } from "../backup-store.mjs";

test("backup encryption requires the paired device token", () => {
  const value = Buffer.from("private wardrobe data");
  const encrypted = encryptBackupBytes(value, "paired-token");
  assert.notDeepEqual(encrypted, value);
  assert.deepEqual(decryptBackupBytes(encrypted, "paired-token"), value);
  assert.throws(() => decryptBackupBytes(encrypted, "different-token"));
});

test("retention keeps daily and weekly restore points", () => {
  const entries = Array.from({ length: 40 }, (_, index) => ({
    name: `snapshot-${index}`,
    timestamp: Date.parse("2026-08-04T12:00:00Z") - index * 86400000
  }));
  const keep = retainedSnapshotNames(entries, 14, 12);
  assert.equal(keep.has("snapshot-0"), true);
  assert.equal(keep.has("snapshot-13"), true);
  assert.equal([...keep].some(name => Number(name.split("-")[1]) >= 35), true);
  assert.equal(keep.size >= 14, true);
  assert.equal(keep.size <= 26, true);
});

test("backup store deduplicates assets and commits encrypted snapshots", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "wearwell-backup-test-"));
  try {
    const store = new BackupStore(root);
    const owner = "a".repeat(64); const token = "paired-token"; const bytes = Buffer.from("image bytes");
    const hash = crypto.createHash("sha256").update(bytes).digest("hex");
    const manifest = { version: 1, assets: [{ name: "garment.jpg", byteCount: bytes.length, sha256: hash }] };
    assert.deepEqual(await store.prepare(owner, manifest), [hash]);
    await store.putAsset(owner, token, hash, bytes.length, bytes);
    assert.deepEqual(await store.prepare(owner, manifest), []);
    const status = await store.commit(owner, token, manifest);
    assert.equal(status.snapshotCount, 1);
    const encrypted = await fs.readFile((await fs.readdir(store.snapshotRoot(owner))).map(name => path.join(store.snapshotRoot(owner), name))[0]);
    assert.throws(() => JSON.parse(encrypted.toString("utf8")));
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test("backup manifests reject unsafe names and false hashes", () => {
  assert.throws(() => validateBackupManifest({ version: 1, assets: [{ name: "../private.jpg", byteCount: 1, sha256: "a".repeat(64) }] }));
  assert.throws(() => validateBackupManifest({ version: 1, assets: [{ name: "safe.jpg", byteCount: 1, sha256: "bad" }] }));
});
