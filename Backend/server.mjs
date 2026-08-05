import http from "node:http";
import { randomUUID } from "node:crypto";
import { loadConfig } from "./config.mjs";
import { createDatabase } from "./database.mjs";
import { createAuthenticator, httpError, requireActiveMember } from "./auth.mjs";
import { readJSON, routeID, send } from "./http.mjs";
import { createStorage, validateAssetMetadata } from "./storage.mjs";

const config = loadConfig();
const db = createDatabase(config.databaseURL);
const storage = createStorage(config);
const authenticate = createAuthenticator(config);

const resources = new Map([
  ["garments", "garments"], ["wishlist", "wishlist_items"], ["outfits", "outfits"],
  ["visualizations", "visualizations"], ["references", "reference_photos"],
  ["inspiration", "inspiration_looks"], ["style-profiles", "style_profiles"],
  ["imports", "import_drafts"], ["style-generations", "style_generations"],
  ["outfit-feedback", "outfit_feedback"], ["outfit-edits", "outfit_edits"]
]);
const jobKinds = new Set(["analyze", "inspiration", "style", "assess", "recommend-item", "catalog-edit", "render"]);

const server = http.createServer(async (req, res) => {
  const requestID = randomUUID();
  try {
    const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    if (req.method === "GET" && url.pathname === "/healthz") return send(res, 200, { status: "ok", environment: config.environment });

    const user = await authenticate(req);
    if (req.method === "POST" && url.pathname === "/v1/invites/redeem") return redeemInvite(req, res, user);
    await requireActiveMember(db, user);

    if (req.method === "GET" && url.pathname === "/v1/sync") return sync(res, user, url);
    if (url.pathname.startsWith("/v1/data/")) return dataRoute(req, res, user, url);
    if (req.method === "POST" && url.pathname === "/v1/assets/upload") return createUpload(req, res, user);
    if (req.method === "POST" && url.pathname === "/v1/assets/finalize") return finalizeUpload(req, res, user);
    const assetID = routeID(url.pathname, "/v1/assets");
    if (assetID && req.method === "GET") return downloadAsset(res, user, assetID);
    if (assetID && req.method === "DELETE") return deleteAsset(res, user, assetID);
    if (url.pathname.startsWith("/v1/jobs/")) return jobsRoute(req, res, user, url);
    if (req.method === "GET" && url.pathname === "/v1/usage") return usage(res, user);
    if (req.method === "POST" && url.pathname === "/v1/backups/import") return importBackup(req, res, user);
    if (req.method === "GET" && url.pathname === "/v1/backups/export") return exportBackup(res, user);
    if (req.method === "DELETE" && url.pathname === "/v1/account") return deleteAccount(res, user);
    throw httpError(404, "Not found.");
  } catch (error) {
    const status = Number(error?.status) || 500;
    if (status >= 500) console.error(JSON.stringify({ level: "error", requestID, message: error?.message || String(error) }));
    send(res, status, { error: status >= 500 ? "The service could not complete the request." : error.message, code: error?.code || null, requestID });
  }
});

async function redeemInvite(req, res, user) {
  const body = await readJSON(req); const code = String(body.code || "").trim();
  if (!/^[A-Za-z0-9-]{6,64}$/.test(code)) throw httpError(400, "Enter a valid invitation code.");
  const { rows } = await db.query("select * from redeem_invite($1,$2,$3)", [user.id, user.email, code]);
  if (!rows.length) throw httpError(403, "Invitation is invalid or expired.");
  send(res, 200, { profile: rows[0] });
}

async function sync(res, user, url) {
  const cursor = Math.max(0, Number(url.searchParams.get("cursor") || 0));
  const { rows } = await db.query("select sequence, resource, record_id, operation, revision, changed_at from sync_changes where owner_id=$1 and sequence>$2 order by sequence limit 500", [user.id, cursor]);
  const records = {};
  for (const change of rows.filter(row => row.operation !== "delete")) {
    const table = resources.get(change.resource); if (!table) continue;
    const result = await db.query(`select id, revision, data, created_at, updated_at, deleted_at from ${table} where owner_id=$1 and id=$2`, [user.id, change.record_id]);
    if (result.rows[0]) (records[change.resource] ||= []).push(result.rows[0]);
  }
  send(res, 200, { cursor: rows.at(-1)?.sequence || cursor, hasMore: rows.length === 500, changes: rows, records });
}

async function dataRoute(req, res, user, url) {
  const match = url.pathname.match(/^\/v1\/data\/([a-z-]+)(?:\/([0-9a-f-]{36}))?$/i);
  if (!match) throw httpError(404, "Not found.");
  const resource = match[1]; const table = resources.get(resource); const id = match[2];
  if (!table) throw httpError(404, "Unknown resource.");
  if (req.method === "GET" && !id) {
    const { rows } = await db.query(`select id, revision, data, created_at, updated_at from ${table} where owner_id=$1 and deleted_at is null order by updated_at`, [user.id]);
    return send(res, 200, { records: rows });
  }
  if (req.method === "PUT" && id) {
    const body = await readJSON(req); const expected = Number(body.revision || 0);
    const { rows } = await db.query(`insert into ${table} (id,owner_id,data) values ($1,$2,$3) on conflict (id) do update set data=excluded.data, revision=${table}.revision+1, updated_at=now(), deleted_at=null where ${table}.owner_id=$2 and ${table}.revision=$4 returning id,revision,data,created_at,updated_at`, [id, user.id, body.data || {}, expected]);
    if (!rows[0]) throw httpError(409, "This record changed on another device. Sync and retry.", "revision_conflict");
    return send(res, expected ? 200 : 201, rows[0]);
  }
  if (req.method === "DELETE" && id) {
    const { rowCount } = await db.query(`update ${table} set deleted_at=now(), updated_at=now(), revision=revision+1 where owner_id=$1 and id=$2 and deleted_at is null`, [user.id, id]);
    if (!rowCount) throw httpError(404, "Record not found."); return send(res, 204, {});
  }
  throw httpError(405, "Method not allowed.");
}

async function createUpload(req, res, user) {
  const body = await readJSON(req); validateAssetMetadata(body);
  const existing = await db.query("select id,storage_path from assets where owner_id=$1 and sha256=$2 and byte_count=$3 and status='ready' and deleted_at is null order by created_at limit 1", [user.id,String(body.sha256).toLowerCase(),body.byteCount]);
  if (existing.rows[0]) return send(res, 200, { assetID: existing.rows[0].id, path: existing.rows[0].storage_path, alreadyUploaded: true });
  const current = await db.query("select coalesce(sum(byte_count),0)::bigint as used from assets where owner_id=$1 and deleted_at is null", [user.id]);
  const profile = await db.query("select storage_limit_bytes from profiles where id=$1", [user.id]);
  if (BigInt(current.rows[0].used) + BigInt(body.byteCount) > BigInt(profile.rows[0].storage_limit_bytes)) throw httpError(429, "Storage limit reached.", "storage_quota");
  const id = randomUUID(); const extension = String(body.mimeType).split("/")[1].replace("jpeg", "jpg"); const path = storage.path(user.id, id, extension);
  await db.query("insert into assets (id,owner_id,kind,storage_path,mime_type,byte_count,sha256,status) values ($1,$2,$3,$4,$5,$6,$7,'uploading')", [id,user.id,String(body.kind||"source").slice(0,40),path,body.mimeType,body.byteCount,String(body.sha256).toLowerCase()]);
  const signed = await storage.signedUpload(path); send(res, 201, { assetID: id, path, ...signed });
}

async function finalizeUpload(req, res, user) {
  const body = await readJSON(req); const { rows } = await db.query("select id,storage_path,byte_count,sha256 from assets where id=$1 and owner_id=$2 and status='uploading'", [body.assetID,user.id]);
  const asset = rows[0]; if (!asset) throw httpError(404, "Pending asset not found.");
  const bytes = await storage.download(asset.storage_path);
  const digest = (await import("node:crypto")).createHash("sha256").update(bytes).digest("hex");
  if (bytes.length !== Number(asset.byte_count) || digest !== asset.sha256) { await storage.remove([asset.storage_path]); await db.query("delete from assets where id=$1", [asset.id]); throw httpError(400, "Uploaded image did not match its declared size or checksum."); }
  await db.query("update assets set status='ready', updated_at=now() where id=$1", [asset.id]); send(res, 200, { assetID: asset.id, status: "ready" });
}

async function downloadAsset(res, user, id) {
  const { rows } = await db.query("select storage_path from assets where id=$1 and owner_id=$2 and status='ready' and deleted_at is null", [id,user.id]);
  if (!rows[0]) throw httpError(404, "Asset not found."); send(res, 200, { url: await storage.signedDownload(rows[0].storage_path), expiresIn: 300 });
}

async function deleteAsset(res, user, id) {
  const { rowCount } = await db.query("update assets set deleted_at=now(),updated_at=now() where id=$1 and owner_id=$2 and deleted_at is null", [id,user.id]);
  if (!rowCount) throw httpError(404, "Asset not found."); send(res, 204, {});
}

async function jobsRoute(req, res, user, url) {
  const create = url.pathname.match(/^\/v1\/jobs\/([a-z-]+)$/); const id = routeID(url.pathname, "/v1/jobs");
  if (req.method === "POST" && create) {
    const kind = create[1]; if (!jobKinds.has(kind)) throw httpError(404, "Unknown job kind.");
    const key = String(req.headers["idempotency-key"] || ""); if (!/^[A-Za-z0-9._:-]{8,128}$/.test(key)) throw httpError(400, "A valid Idempotency-Key header is required.");
    const body = await readJSON(req, 4 * 1024 * 1024);
    const { rows } = await db.query("select * from create_job_with_quota($1,$2,$3,$4)", [user.id,kind,key,body]);
    if (!rows[0]) throw httpError(429, "Monthly AI limit reached.", "usage_quota"); return send(res, 202, rows[0]);
  }
  if (id && req.method === "GET") {
    const { rows } = await db.query("select id,kind,state,stage,progress_completed,progress_total,result,error_code,error_message as error,created_at,updated_at from jobs where id=$1 and owner_id=$2", [id,user.id]);
    if (!rows[0]) throw httpError(404, "Job not found."); return send(res, 200, rows[0]);
  }
  if (id && req.method === "DELETE") {
    const { rowCount } = await db.query("update jobs set state='cancelled',cancel_requested_at=now(),request=jsonb_build_object('cancelled',true),updated_at=now() where id=$1 and owner_id=$2 and state in ('queued','processing')", [id,user.id]);
    if (!rowCount) throw httpError(409, "Job cannot be cancelled."); return send(res, 204, {});
  }
  throw httpError(405, "Method not allowed.");
}

async function usage(res, user) {
  const { rows } = await db.query("select * from current_usage($1)", [user.id]); send(res, 200, rows[0] || {});
}

async function importBackup(req, res, user) {
  const body = await readJSON(req, 8 * 1024 * 1024); const manifest = body.manifest;
  if (!manifest || manifest.version !== 1) throw httpError(400, "Unsupported backup manifest.");
  const collections = manifest.records || {
    garments: manifest.garments, wishlist: manifest.wishlistItems, outfits: manifest.outfits,
    visualizations: manifest.visualizations, references: manifest.referencePhotos,
    inspiration: manifest.inspirationLooks, "style-profiles": manifest.styleProfiles
  };
  if (typeof collections !== "object") throw httpError(400, "Backup records are missing.");
  const assetIDs = body.assetIDs && typeof body.assetIDs === "object" ? body.assetIDs : {};
  let count = 0;
  await db.transaction(async client => {
    for (const [resource, records] of Object.entries(collections)) {
      const table = resources.get(resource); if (!table || !Array.isArray(records)) continue;
      for (const record of records.slice(0, 5000)) {
        if (!/^[0-9a-f-]{36}$/i.test(String(record.id || ""))) throw httpError(400, "Backup contains an invalid record ID.");
        const data = replaceAssetNames(record.data || record, assetIDs);
        await client.query(`insert into ${table} (id,owner_id,data) values ($1,$2,$3) on conflict (id) do update set data=excluded.data,revision=${table}.revision+1,updated_at=now(),deleted_at=null where ${table}.owner_id=$2`, [record.id,user.id,data]); count++;
      }
    }
  });
  send(res, 200, { importedRecords: count, merge: true });
}

function replaceAssetNames(value, mapping) {
  if (Array.isArray(value)) return value.map(item => replaceAssetNames(item, mapping));
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value).map(([key,item]) => [key, /assetname$/i.test(key) && typeof item === "string" ? (mapping[item] || item) : replaceAssetNames(item,mapping)]));
}

async function exportBackup(res, user) {
  const records = {};
  for (const [resource, table] of resources) records[resource] = (await db.query(`select id,data,created_at,updated_at from ${table} where owner_id=$1 and deleted_at is null`, [user.id])).rows;
  const assets = (await db.query("select id,kind,mime_type,byte_count,sha256,storage_path from assets where owner_id=$1 and status='ready' and deleted_at is null", [user.id])).rows;
  const downloads = [];
  for (const asset of assets) downloads.push({ name: asset.id, url: await storage.signedDownload(asset.storage_path, 900) });
  const values = resource => (records[resource] || []).map(record => record.data);
  const manifest = {
    version: 1, createdAt: new Date().toISOString(),
    garments: values("garments"), wishlistItems: values("wishlist"), outfits: values("outfits"),
    visualizations: values("visualizations"), referencePhotos: values("references"),
    inspirationLooks: values("inspiration"), styleProfiles: values("style-profiles"),
    assets: assets.map(asset => ({ name: asset.id, byteCount: Number(asset.byte_count), sha256: asset.sha256 }))
  };
  send(res, 200, { manifest, downloads });
}

async function deleteAccount(res, user) {
  await db.transaction(async client => {
    await client.query("update profiles set status='deleting',updated_at=now() where id=$1", [user.id]);
    await client.query("insert into deletion_requests (owner_id,purge_after) values ($1,now()+interval '7 days') on conflict (owner_id) do nothing", [user.id]);
  });
  send(res, 202, { status: "locked", purgeWithinDays: 7 });
}

server.listen(config.port, "0.0.0.0", () => console.log(JSON.stringify({ level: "info", message: "Wearwell API listening", port: config.port, environment: config.environment })));

for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, async () => { server.close(); await db.close(); process.exit(0); });
