import crypto, { randomUUID } from "node:crypto";

export async function loadAssets(db, storage, ownerID, ids, limit = 16) {
  const unique = [...new Set((ids || []).map(String))].slice(0, limit);
  if (!unique.length) return [];
  const { rows } = await db.query(
    "select id, storage_path, mime_type from assets where owner_id = $1 and id = any($2::uuid[]) and status = 'ready' and deleted_at is null",
    [ownerID, unique]
  );
  const byID = new Map(rows.map(row => [row.id, row]));
  const result = [];
  for (const id of unique) {
    const row = byID.get(id); if (!row) throw new Error(`Asset ${id} is unavailable.`);
    result.push({ id, mimeType: row.mime_type, bytes: await storage.download(row.storage_path) });
  }
  return result;
}

export async function saveGeneratedAsset(db, storage, ownerID, bytes, kind) {
  const id = randomUUID(); const mimeType = "image/png";
  const path = storage.path(ownerID, id, "png");
  await storage.upload(path, bytes, mimeType);
  await db.query(
    "insert into assets (id, owner_id, kind, storage_path, mime_type, byte_count, sha256, status) values ($1,$2,$3,$4,$5,$6,$7,'ready')",
    [id, ownerID, kind, path, mimeType, bytes.length, crypto.createHash("sha256").update(bytes).digest("hex")]
  );
  return id;
}
