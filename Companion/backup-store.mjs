import crypto, { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

export const DAILY_RETENTION = 14;
export const WEEKLY_RETENTION = 12;

function encryptionKey(token) {
  return crypto.createHash("sha256").update(`wearwell-backup-v1:${token}`).digest();
}

export function encryptBackupBytes(bytes, token) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", encryptionKey(token), iv);
  const encrypted = Buffer.concat([cipher.update(bytes), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), encrypted]);
}

export function decryptBackupBytes(bytes, token) {
  if (bytes.length < 28) throw new Error("Encrypted backup data is damaged.");
  const decipher = crypto.createDecipheriv("aes-256-gcm", encryptionKey(token), bytes.subarray(0, 12));
  decipher.setAuthTag(bytes.subarray(12, 28));
  return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]);
}

function dayKey(date) { return date.toISOString().slice(0, 10); }
function weekKey(date) {
  const value = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  value.setUTCDate(value.getUTCDate() + 4 - (value.getUTCDay() || 7));
  const yearStart = new Date(Date.UTC(value.getUTCFullYear(), 0, 1));
  const week = Math.ceil((((value - yearStart) / 86400000) + 1) / 7);
  return `${value.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}

export function retainedSnapshotNames(entries, dailyLimit = DAILY_RETENTION, weeklyLimit = WEEKLY_RETENTION) {
  const sorted = [...entries].filter(entry => Number.isFinite(entry.timestamp)).sort((a, b) => b.timestamp - a.timestamp);
  const keep = new Set();
  const days = new Set();
  const weeks = new Set();
  for (const entry of sorted) {
    const date = new Date(entry.timestamp);
    const day = dayKey(date);
    const week = weekKey(date);
    if (days.size < dailyLimit && !days.has(day)) { days.add(day); keep.add(entry.name); }
    if (weeks.size < weeklyLimit && !weeks.has(week)) { weeks.add(week); keep.add(entry.name); }
  }
  if (sorted[0]) keep.add(sorted[0].name);
  return keep;
}

function safeOwner(owner) {
  if (!/^[0-9a-f]{64}$/i.test(owner)) throw new Error("Invalid backup owner.");
  return owner.toLowerCase();
}
function safeHash(hash) {
  if (!/^[0-9a-f]{64}$/i.test(hash)) throw new Error("Invalid backup image hash.");
  return hash.toLowerCase();
}
function safeAssetName(name) {
  return typeof name === "string" && name.length > 0 && name.length <= 255 && name === path.basename(name) && !name.includes("\\");
}

export function validateBackupManifest(value) {
  if (!value || value.version !== 1 || !Array.isArray(value.assets)) throw new Error("Unsupported or invalid backup manifest.");
  if (value.assets.length > 5000) throw new Error("Backup contains too many images.");
  const names = new Set();
  let totalBytes = 0;
  for (const asset of value.assets) {
    if (!safeAssetName(asset.name) || names.has(asset.name)) throw new Error("Backup contains an invalid or duplicate image name.");
    safeHash(asset.sha256);
    if (!Number.isSafeInteger(asset.byteCount) || asset.byteCount < 0 || asset.byteCount > 18 * 1024 * 1024) throw new Error("Backup image size is invalid.");
    names.add(asset.name); totalBytes += asset.byteCount;
  }
  if (totalBytes > 5 * 1024 * 1024 * 1024) throw new Error("Backup is larger than 5 GB.");
  return value;
}

export class BackupStore {
  constructor(root) { this.root = root; }
  ownerRoot(owner) { return path.join(this.root, safeOwner(owner)); }
  blobPath(owner, hash) { return path.join(this.ownerRoot(owner), "blobs", `${safeHash(hash)}.enc`); }
  snapshotRoot(owner) { return path.join(this.ownerRoot(owner), "snapshots"); }

  async prepare(owner, manifest) {
    validateBackupManifest(manifest);
    const missingHashes = [];
    for (const asset of manifest.assets) {
      try {
        const stat = await fs.stat(this.blobPath(owner, asset.sha256));
        if (stat.size !== asset.byteCount + 28) missingHashes.push(asset.sha256);
      } catch { missingHashes.push(asset.sha256); }
    }
    return [...new Set(missingHashes)];
  }

  async putAsset(owner, token, hash, byteCount, bytes) {
    hash = safeHash(hash);
    if (!Number.isSafeInteger(byteCount) || byteCount !== bytes.length || byteCount > 18 * 1024 * 1024) throw new Error("Backup image size does not match.");
    if (crypto.createHash("sha256").update(bytes).digest("hex") !== hash) throw new Error("Backup image checksum does not match.");
    const target = this.blobPath(owner, hash);
    await fs.mkdir(path.dirname(target), { recursive: true });
    const temporary = `${target}.${randomUUID()}.tmp`;
    await fs.writeFile(temporary, encryptBackupBytes(bytes, token), { mode: 0o600 });
    await fs.rename(temporary, target);
  }

  async commit(owner, token, manifest) {
    validateBackupManifest(manifest);
    const missing = await this.prepare(owner, manifest);
    if (missing.length) throw new Error(`Backup is missing ${missing.length} image${missing.length === 1 ? "" : "s"}.`);
    const createdAt = new Date().toISOString();
    const filename = `${createdAt.replaceAll(":", "-")}-${randomUUID()}.json.enc`;
    const folder = this.snapshotRoot(owner);
    await fs.mkdir(folder, { recursive: true });
    const target = path.join(folder, filename);
    const temporary = `${target}.tmp`;
    await fs.writeFile(temporary, encryptBackupBytes(Buffer.from(JSON.stringify({ createdAt, manifest })), token), { mode: 0o600 });
    await fs.rename(temporary, target);
    await this.prune(owner, token);
    return this.status(owner);
  }

  async entries(owner) {
    let names = []; try { names = await fs.readdir(this.snapshotRoot(owner)); } catch { return []; }
    const entries = [];
    for (const name of names) {
      if (!name.endsWith(".json.enc")) continue;
      const prefix = name.slice(0, 24).replace(/^(\d{4}-\d\d-\d\dT\d\d)-(\d\d)-(\d\d\.\d{3}Z)$/, "$1:$2:$3");
      const timestamp = Date.parse(prefix);
      if (Number.isFinite(timestamp)) entries.push({ name, timestamp });
    }
    return entries;
  }

  async prune(owner, token) {
    const entries = await this.entries(owner);
    const keep = retainedSnapshotNames(entries);
    for (const entry of entries) if (!keep.has(entry.name)) await fs.rm(path.join(this.snapshotRoot(owner), entry.name), { force: true });

    const referenced = new Set();
    for (const entry of entries.filter(value => keep.has(value.name))) {
      try {
        const encrypted = await fs.readFile(path.join(this.snapshotRoot(owner), entry.name));
        const snapshot = JSON.parse(decryptBackupBytes(encrypted, token));
        for (const asset of snapshot.manifest.assets || []) referenced.add(asset.sha256);
      } catch { /* Retain unknown blobs if a snapshot cannot be read. */ return; }
    }
    let blobs = []; try { blobs = await fs.readdir(path.join(this.ownerRoot(owner), "blobs")); } catch { return; }
    for (const name of blobs) {
      const hash = name.replace(/\.enc$/, "");
      if (name.endsWith(".enc") && !referenced.has(hash)) await fs.rm(path.join(this.ownerRoot(owner), "blobs", name), { force: true });
    }
  }

  async status(owner) {
    const entries = (await this.entries(owner)).sort((a, b) => b.timestamp - a.timestamp);
    const dayCount = new Set(entries.map(entry => dayKey(new Date(entry.timestamp)))).size;
    const weekCount = new Set(entries.map(entry => weekKey(new Date(entry.timestamp)))).size;
    return {
      latestAt: entries[0] ? new Date(entries[0].timestamp).toISOString() : null,
      snapshotCount: entries.length,
      dailySnapshots: Math.min(dayCount, DAILY_RETENTION),
      weeklySnapshots: Math.min(weekCount, WEEKLY_RETENTION),
      retention: { daily: DAILY_RETENTION, weekly: WEEKLY_RETENTION }
    };
  }
}
