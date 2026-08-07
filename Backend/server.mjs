import http from "node:http";
import { randomUUID } from "node:crypto";
import { loadConfig } from "./config.mjs";
import { createDatabase } from "./database.mjs";
import { createAuthenticator, httpError, requireActiveMember } from "./auth.mjs";
import { readJSON, routeID, send } from "./http.mjs";
import { createStorage, validateAssetMetadata } from "./storage.mjs";
import {
  FRIEND_INVITE_TTL_DAYS, canonicalFriendPair, createFriendInviteToken,
  hashFriendInviteToken, isFriendInviteToken, normalizedDisplayName, validateShareSnapshot
} from "./social.mjs";

const config = loadConfig();
const db = createDatabase(config.databaseURL);
const storage = createStorage(config);
const authenticate = createAuthenticator(config);

const resources = new Map([
  ["garments", "garments"], ["wishlist", "wishlist_items"], ["outfits", "outfits"],
  ["visualizations", "visualizations"], ["references", "reference_photos"],
  ["inspiration", "inspiration_looks"], ["style-profiles", "style_profiles"],
  ["imports", "import_drafts"], ["style-generations", "style_generations"],
  ["outfit-feedback", "outfit_feedback"], ["outfit-ratings", "outfit_ratings"], ["outfit-edits", "outfit_edits"]
]);
const jobKinds = new Set(["analyze", "inspiration", "style", "assess", "recommend-item", "catalog-edit", "render"]);

const server = http.createServer(async (req, res) => {
  const requestID = randomUUID();
  const startedAt = Date.now();
  res.on("finish", () => console.log(JSON.stringify({
    level: "info", event: "http_request", requestID, method: req.method,
    route: routeTemplate(req.url), status: res.statusCode, latencyMs: Date.now()-startedAt
  })));
  try {
    const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    if (req.method === "GET" && url.pathname === "/healthz") return send(res, 200, { status: "ok", environment: config.environment });

    const user = await authenticate(req);
    if (req.method === "POST" && url.pathname === "/v1/invites/redeem") return redeemInvite(req, res, user);
    await requireActiveMember(db, user);

    if (url.pathname === "/v1/profile") return profileRoute(req, res, user);
    if (url.pathname.startsWith("/v1/friend-invites")) return friendInviteRoute(req, res, user, url);
    if (url.pathname.startsWith("/v1/friends")) return friendsRoute(req, res, user, url);
    if (url.pathname.startsWith("/v1/blocks")) return blocksRoute(req, res, user, url);
    if (url.pathname.startsWith("/v1/shares")) return sharesRoute(req, res, user, url);
    if (url.pathname.startsWith("/v1/activity")) return activityRoute(req, res, user, url);
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

function routeTemplate(rawURL = "") {
  const pathname = String(rawURL).split("?")[0];
  return pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/ig,":id").replace(/\/friend-invite\/[A-Za-z0-9_-]+/g,"/friend-invite/:token");
}

async function redeemInvite(req, res, user) {
  const body = await readJSON(req); const code = String(body.code || "").trim();
  if (!/^[A-Za-z0-9-]{6,64}$/.test(code)) throw httpError(400, "Enter a valid invitation code.");
  const { rows } = await db.query("select * from redeem_invite($1,$2,$3)", [user.id, user.email, code]);
  if (!rows.length) throw httpError(403, "Invitation is invalid or expired.");
  send(res, 200, { profile: rows[0] });
}

async function profileRoute(req, res, user) {
  if (req.method === "GET") {
    const { rows } = await db.query("select id,coalesce(display_name,'') as display_name,avatar_asset_id,created_at from profiles where id=$1", [user.id]);
    return send(res, 200, rows[0]);
  }
  if (req.method === "PUT") {
    const body = await readJSON(req);
    const displayName = normalizedDisplayName(body.displayName);
    let avatarAssetID = body.avatarAssetID || null;
    if (avatarAssetID) {
      const asset = await db.query("select id from assets where id=$1 and owner_id=$2 and status='ready' and deleted_at is null", [avatarAssetID,user.id]);
      if (!asset.rows[0]) throw httpError(400, "Avatar image is unavailable.");
    }
    const { rows } = await db.query("update profiles set display_name=$2,avatar_asset_id=$3,revision=revision+1,updated_at=now() where id=$1 returning id,display_name,avatar_asset_id,created_at", [user.id,displayName,avatarAssetID]);
    return send(res, 200, rows[0]);
  }
  throw httpError(405, "Method not allowed.");
}

async function friendInviteRoute(req, res, user, url) {
  if (req.method === "POST" && url.pathname === "/v1/friend-invites") {
    await enforceRateLimit(user.id, "friend-invite", 10, 3600);
    const token = createFriendInviteToken();
    const expiresAt = new Date(Date.now() + FRIEND_INVITE_TTL_DAYS * 86400000);
    const { rows } = await db.query(
      "insert into friend_invites(inviter_id,token_hash,expires_at) values($1,$2,$3) returning id,expires_at,created_at",
      [user.id,hashFriendInviteToken(token),expiresAt]
    );
    return send(res, 201, { ...rows[0], token, url: `wearwell://friend-invite/${token}` });
  }
  if (req.method === "POST" && url.pathname === "/v1/friend-invites/redeem") {
    await enforceRateLimit(user.id, "friend-redeem", 20, 3600);
    const body = await readJSON(req); const token = String(body.token || "");
    if (!isFriendInviteToken(token)) throw httpError(400, "Friend invitation is invalid.");
    const result = await db.transaction(async client => {
      const inviteResult = await client.query(
        "select id,inviter_id from friend_invites where token_hash=$1 and redeemed_at is null and revoked_at is null and expires_at>now() for update",
        [hashFriendInviteToken(token)]
      );
      const invite = inviteResult.rows[0];
      if (!invite) throw httpError(404, "Friend invitation is invalid or expired.", "friend_invite_expired");
      if (invite.inviter_id === user.id) throw httpError(400, "You cannot accept your own invitation.");
      if (await usersAreBlocked(client, invite.inviter_id, user.id)) throw httpError(403, "This connection is unavailable.");
      const [low, high] = canonicalFriendPair(invite.inviter_id,user.id);
      await client.query("insert into friendships(user_low,user_high) values($1,$2) on conflict do nothing", [low,high]);
      await client.query("update friend_invites set redeemed_by=$2,redeemed_at=now() where id=$1", [invite.id,user.id]);
      await client.query("insert into activity_events(recipient_id,actor_id,kind,object_id) values($1,$2,'friend_accepted',$3)", [invite.inviter_id,user.id,invite.id]);
      const friend = await client.query("select id,coalesce(display_name,'Wearwell friend') as display_name from profiles where id=$1", [invite.inviter_id]);
      return friend.rows[0];
    });
    return send(res, 200, { friend: result });
  }
  throw httpError(405, "Method not allowed.");
}

async function friendsRoute(req, res, user, url) {
  if (req.method === "GET" && url.pathname === "/v1/friends") {
    const { rows } = await db.query(`
      select p.id,coalesce(p.display_name,'Wearwell friend') as display_name,p.avatar_asset_id,f.created_at
      from friendships f join profiles p on p.id=case when f.user_low=$1 then f.user_high else f.user_low end
      where (f.user_low=$1 or f.user_high=$1)
        and not exists(select 1 from blocks b where (b.blocker_id=$1 and b.blocked_id=p.id) or (b.blocker_id=p.id and b.blocked_id=$1))
      order by p.display_name nulls last,f.created_at`, [user.id]);
    return send(res, 200, { friends: rows });
  }
  const friendID = routeID(url.pathname, "/v1/friends");
  if (friendID && req.method === "DELETE") {
    const [low,high] = canonicalFriendPair(user.id,friendID);
    await db.query("delete from friendships where user_low=$1 and user_high=$2", [low,high]);
    return send(res, 204, {});
  }
  throw httpError(405, "Method not allowed.");
}

async function blocksRoute(req, res, user, url) {
  const blockedID = routeID(url.pathname, "/v1/blocks");
  if (!blockedID) throw httpError(404, "Member not found.");
  if (req.method === "POST") {
    if (blockedID === user.id) throw httpError(400, "You cannot block yourself.");
    const [low,high] = canonicalFriendPair(user.id,blockedID);
    await db.transaction(async client => {
      await client.query("insert into blocks(blocker_id,blocked_id) values($1,$2) on conflict do nothing", [user.id,blockedID]);
      await client.query("delete from friendships where user_low=$1 and user_high=$2", [low,high]);
      await client.query("update outfit_shares set revoked_at=now() where revoked_at is null and ((sender_id=$1 and recipient_id=$2) or (sender_id=$2 and recipient_id=$1))", [user.id,blockedID]);
    });
    return send(res, 204, {});
  }
  if (req.method === "DELETE") {
    await db.query("delete from blocks where blocker_id=$1 and blocked_id=$2", [user.id,blockedID]);
    return send(res, 204, {});
  }
  throw httpError(405, "Method not allowed.");
}

async function sharesRoute(req, res, user, url) {
  if (req.method === "POST" && url.pathname === "/v1/shares") return createShare(req,res,user);
  if (req.method === "GET" && url.pathname === "/v1/shares/inbox") return listShares(res,user,url);
  const reactionMatch = url.pathname.match(/^\/v1\/shares\/([0-9a-f-]{36})\/reaction$/i);
  if (reactionMatch) return reactionRoute(req,res,user,reactionMatch[1]);
  const copyMatch = url.pathname.match(/^\/v1\/shares\/([0-9a-f-]{36})\/copy$/i);
  if (copyMatch && req.method === "POST") return copyShare(res,user,copyMatch[1]);
  const shareID = routeID(url.pathname, "/v1/shares");
  if (shareID && req.method === "GET") return getShare(res,user,shareID);
  if (shareID && req.method === "DELETE") {
    const { rowCount } = await db.query("update outfit_shares set revoked_at=now() where id=$1 and sender_id=$2 and revoked_at is null", [shareID,user.id]);
    if (!rowCount) throw httpError(404, "Share not found.");
    await db.query("delete from asset_references where owner_id=$1 and resource='outfit-shares' and record_id=$2", [user.id,shareID]);
    return send(res, 204, {});
  }
  throw httpError(405, "Method not allowed.");
}

async function createShare(req,res,user) {
  await enforceRateLimit(user.id, "share", 60, 3600);
  const key = String(req.headers["idempotency-key"] || "");
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(key)) throw httpError(400,"A valid Idempotency-Key header is required.");
  const existing = await db.query("select id,created_at from outfit_shares where sender_id=$1 and idempotency_key=$2",[user.id,key]);
  if (existing.rows[0]) return send(res,200,existing.rows[0]);
  const body = await readJSON(req); const recipientID = String(body.recipientID || "");
  if (!/^[0-9a-f-]{36}$/i.test(recipientID)) throw httpError(400, "Choose a friend.");
  if (!await areFriends(db,user.id,recipientID) || await usersAreBlocked(db,user.id,recipientID)) throw httpError(403, "You can share only with an accepted friend.");
  const previewAssetID = String(body.previewAssetID || "");
  const asset = await db.query("select id from assets where id=$1 and owner_id=$2 and status='ready' and deleted_at is null", [previewAssetID,user.id]);
  if (!asset.rows[0]) throw httpError(400, "Shared preview is unavailable.");
  const snapshot = validateShareSnapshot(body.snapshot);
  const sourceOutfitID = /^[0-9a-f-]{36}$/i.test(String(body.sourceOutfitID || "")) ? body.sourceOutfitID : null;
  const value = await db.transaction(async client => {
    const { rows } = await client.query("insert into outfit_shares(sender_id,recipient_id,idempotency_key,source_outfit_id,preview_asset_id,snapshot) values($1,$2,$3,$4,$5,$6) returning id,created_at", [user.id,recipientID,key,sourceOutfitID,previewAssetID,snapshot]);
    await client.query("insert into asset_references(owner_id,asset_id,resource,record_id) values($1,$2,'outfit-shares',$3) on conflict do nothing", [user.id,previewAssetID,rows[0].id]);
    await client.query("insert into activity_events(recipient_id,actor_id,kind,object_id) values($1,$2,'share_received',$3)", [recipientID,user.id,rows[0].id]);
    return rows[0];
  });
  return send(res,201,value);
}

async function listShares(res,user,url) {
  const before = Math.max(0,Number(url.searchParams.get("before") || Number.MAX_SAFE_INTEGER));
  const { rows } = await db.query(`
    select s.id,s.sender_id,s.snapshot,s.created_at,p.display_name,
      exists(select 1 from share_reactions r where r.share_id=s.id and r.user_id=$1) as reacted,
      exists(select 1 from share_copies c where c.share_id=s.id and c.recipient_id=$1) as copied
    from outfit_shares s join profiles p on p.id=s.sender_id
    where s.recipient_id=$1 and s.revoked_at is null and extract(epoch from s.created_at)*1000 < $2
      and not exists(select 1 from blocks b where (b.blocker_id=$1 and b.blocked_id=s.sender_id) or (b.blocker_id=s.sender_id and b.blocked_id=$1))
    order by s.created_at desc limit 50`, [user.id,before]);
  return send(res,200,{ shares: rows, nextBefore: rows.length === 50 ? new Date(rows.at(-1).created_at).getTime() : null });
}

async function getShare(res,user,shareID) {
  const { rows } = await db.query(`
    select s.*,p.display_name,a.storage_path,
      exists(select 1 from share_reactions r where r.share_id=s.id and r.user_id=$2) as reacted,
      exists(select 1 from share_copies c where c.share_id=s.id and c.recipient_id=$2) as copied
    from outfit_shares s join profiles p on p.id=s.sender_id join assets a on a.id=s.preview_asset_id
    where s.id=$1 and (s.sender_id=$2 or s.recipient_id=$2) and s.revoked_at is null and a.status='ready' and a.deleted_at is null
      and not exists(select 1 from blocks b where (b.blocker_id=$2 and b.blocked_id=case when s.sender_id=$2 then s.recipient_id else s.sender_id end) or (b.blocked_id=$2 and b.blocker_id=case when s.sender_id=$2 then s.recipient_id else s.sender_id end))`, [shareID,user.id]);
  if (!rows[0]) throw httpError(404,"Share not found.");
  const value = rows[0]; const previewURL = await storage.signedDownload(value.storage_path);
  delete value.storage_path; return send(res,200,{...value,previewURL,expiresIn:300});
}

async function reactionRoute(req,res,user,shareID) {
  const share = await db.query("select sender_id,recipient_id from outfit_shares where id=$1 and recipient_id=$2 and revoked_at is null", [shareID,user.id]);
  if (!share.rows[0] || await usersAreBlocked(db,share.rows[0].sender_id,user.id)) throw httpError(404,"Share not found.");
  if (req.method === "PUT") {
    const { rowCount } = await db.query("insert into share_reactions(share_id,user_id) values($1,$2) on conflict do nothing", [shareID,user.id]);
    if (rowCount) await db.query("insert into activity_events(recipient_id,actor_id,kind,object_id) values($1,$2,'reaction_received',$3)", [share.rows[0].sender_id,user.id,shareID]);
    return send(res,200,{kind:"heart"});
  }
  if (req.method === "DELETE") { await db.query("delete from share_reactions where share_id=$1 and user_id=$2", [shareID,user.id]); return send(res,204,{}); }
  throw httpError(405,"Method not allowed.");
}

async function copyShare(res,user,shareID) {
  const existing = await db.query("select inspiration_id,asset_id from share_copies where share_id=$1 and recipient_id=$2", [shareID,user.id]);
  if (existing.rows[0]) return send(res,200,existing.rows[0]);
  const { rows } = await db.query(`select s.snapshot,a.storage_path,a.mime_type,a.byte_count,a.sha256
    from outfit_shares s join assets a on a.id=s.preview_asset_id
    where s.id=$1 and s.recipient_id=$2 and s.revoked_at is null and a.status='ready' and a.deleted_at is null`, [shareID,user.id]);
  const source = rows[0]; if (!source || await usersAreBlocked(db,user.id,(await db.query("select sender_id from outfit_shares where id=$1",[shareID])).rows[0]?.sender_id)) throw httpError(404,"Share not found.");
  const bytes = await storage.download(source.storage_path); const assetID = randomUUID(); const inspirationID = randomUUID();
  const extension = source.mime_type.split("/")[1].replace("jpeg","jpg"); const path = storage.path(user.id,assetID,extension);
  await storage.upload(path,bytes,source.mime_type);
  try {
    await db.transaction(async client => {
      await client.query("insert into assets(id,owner_id,kind,storage_path,mime_type,byte_count,sha256,status) values($1,$2,'shared-inspiration',$3,$4,$5,$6,'ready')", [assetID,user.id,path,source.mime_type,source.byte_count,source.sha256]);
      const now = new Date().toISOString();
      const data = { id: inspirationID, assetName: assetID, sourceURL: null, state: "ready", analysisJSON: null, errorMessage: null, isFavorite: false, createdAt: now, updatedAt: now };
      await client.query("insert into inspiration_looks(id,owner_id,data) values($1,$2,$3)", [inspirationID,user.id,data]);
      await client.query("insert into asset_references(owner_id,asset_id,resource,record_id) values($1,$2,'inspiration',$3)", [user.id,assetID,inspirationID]);
      await client.query("insert into share_copies(share_id,recipient_id,inspiration_id,asset_id) values($1,$2,$3,$4)", [shareID,user.id,inspirationID,assetID]);
    });
  } catch (error) {
    await storage.remove([path]).catch(()=>{});
    if (error?.code === "23505") {
      const winner = await db.query("select inspiration_id,asset_id from share_copies where share_id=$1 and recipient_id=$2",[shareID,user.id]);
      if (winner.rows[0]) return send(res,200,winner.rows[0]);
    }
    throw error;
  }
  return send(res,201,{inspirationID,assetID});
}

async function activityRoute(req,res,user,url) {
  if (req.method === "GET" && url.pathname === "/v1/activity") {
    const before = Math.max(0,Number(url.searchParams.get("before") || Number.MAX_SAFE_INTEGER));
    const { rows } = await db.query(`select e.id,e.kind,e.object_id,e.created_at,e.read_at,e.actor_id,coalesce(p.display_name,'Wearwell friend') as actor_name
      from activity_events e left join profiles p on p.id=e.actor_id where e.recipient_id=$1 and e.id<$2 order by e.id desc limit 50`, [user.id,before]);
    return send(res,200,{events:rows,nextBefore:rows.length===50?rows.at(-1).id:null});
  }
  if (req.method === "POST" && url.pathname === "/v1/activity/read") {
    const body = await readJSON(req); const through = Number(body.throughID || 0);
    if (!Number.isSafeInteger(through) || through < 1) throw httpError(400,"Choose a valid activity.");
    await db.query("update activity_events set read_at=coalesce(read_at,now()) where recipient_id=$1 and id<=$2", [user.id,through]);
    return send(res,204,{});
  }
  throw httpError(405,"Method not allowed.");
}

async function enforceRateLimit(ownerID,scope,limit,seconds) {
  const { rows } = await db.query("select consume_rate_limit($1,$2,$3,$4) as allowed", [ownerID,scope,limit,seconds]);
  if (!rows[0]?.allowed) throw httpError(429,"Too many requests. Try again later.","rate_limited");
}

async function areFriends(client,first,second) {
  const [low,high] = canonicalFriendPair(first,second);
  return Boolean((await client.query("select 1 from friendships where user_low=$1 and user_high=$2",[low,high])).rows[0]);
}

async function usersAreBlocked(client,first,second) {
  return Boolean((await client.query("select 1 from blocks where (blocker_id=$1 and blocked_id=$2) or (blocker_id=$2 and blocked_id=$1) limit 1",[first,second])).rows[0]);
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
    await syncAssetReferences(db, user.id, resource, id, rows[0].data);
    return send(res, expected ? 200 : 201, rows[0]);
  }
  if (req.method === "DELETE" && id) {
    const { rowCount } = await db.query(`update ${table} set deleted_at=now(), updated_at=now(), revision=revision+1 where owner_id=$1 and id=$2 and deleted_at is null`, [user.id, id]);
    if (!rowCount) throw httpError(404, "Record not found.");
    await db.query("delete from asset_references where owner_id=$1 and resource=$2 and record_id=$3", [user.id,resource,id]);
    return send(res, 204, {});
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
  const { rowCount } = await db.query("update assets set deleted_at=now(),updated_at=now() where id=$1 and owner_id=$2 and deleted_at is null and not exists(select 1 from asset_references where asset_id=assets.id)", [id,user.id]);
  if (!rowCount) throw httpError(409, "Asset is missing or still referenced by a record."); send(res, 204, {});
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
        await client.query(`insert into ${table} (id,owner_id,data) values ($1,$2,$3) on conflict (id) do update set data=excluded.data,revision=${table}.revision+1,updated_at=now(),deleted_at=null where ${table}.owner_id=$2`, [record.id,user.id,data]);
        await syncAssetReferences(client, user.id, resource, record.id, data); count++;
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

async function syncAssetReferences(client, ownerID, resource, recordID, data) {
  await client.query("delete from asset_references where owner_id=$1 and resource=$2 and record_id=$3", [ownerID,resource,recordID]);
  const candidates = [...collectUUIDs(data)];
  if (!candidates.length) return;
  const { rows } = await client.query("select id from assets where owner_id=$1 and id=any($2::uuid[]) and deleted_at is null", [ownerID,candidates]);
  for (const row of rows) await client.query("insert into asset_references(owner_id,asset_id,resource,record_id) values($1,$2,$3,$4) on conflict do nothing", [ownerID,row.id,resource,recordID]);
}

function collectUUIDs(value, result = new Set()) {
  if (typeof value === "string" && /^[0-9a-f-]{36}$/i.test(value)) result.add(value);
  else if (Array.isArray(value)) for (const item of value) collectUUIDs(item,result);
  else if (value && typeof value === "object") for (const item of Object.values(value)) collectUUIDs(item,result);
  return result;
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
