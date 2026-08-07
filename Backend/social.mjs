import crypto from "node:crypto";

export const FRIEND_INVITE_TTL_DAYS = 7;

export function createFriendInviteToken() {
  return crypto.randomBytes(24).toString("base64url");
}

export function hashFriendInviteToken(token) {
  return crypto.createHash("sha256").update(String(token || "").trim()).digest();
}

export function isFriendInviteToken(token) {
  return /^[A-Za-z0-9_-]{24,128}$/.test(String(token || ""));
}

export function normalizedDisplayName(value) {
  const name = String(value || "").trim().replace(/\s+/g, " ");
  if (name.length < 1 || name.length > 50) throw Object.assign(new Error("Display name must be 1–50 characters."), { status: 400 });
  if (/\p{C}/u.test(name)) throw Object.assign(new Error("Display name contains unsupported characters."), { status: 400 });
  return name;
}

export function canonicalFriendPair(first, second) {
  const values = [String(first), String(second)].sort();
  if (!values[0] || values[0] === values[1]) throw Object.assign(new Error("Choose another Wearwell member."), { status: 400 });
  return values;
}

export function validateShareSnapshot(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw Object.assign(new Error("A share snapshot is required."), { status: 400 });
  const title = String(value.title || "").trim().slice(0, 120);
  const rationale = String(value.rationale || "").trim().slice(0, 600);
  if (!title) throw Object.assign(new Error("The shared outfit needs a title."), { status: 400 });
  return { version: 1, title, rationale };
}
