import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import {
  canonicalFriendPair, createFriendInviteToken, hashFriendInviteToken,
  isFriendInviteToken, normalizedDisplayName, validateShareSnapshot
} from "../social.mjs";

test("friend invitation tokens are high entropy, URL safe, and hashed", () => {
  const first = createFriendInviteToken(); const second = createFriendInviteToken();
  assert.notEqual(first,second); assert.equal(isFriendInviteToken(first),true);
  assert.equal(hashFriendInviteToken(first).length,32);
  assert.equal(hashFriendInviteToken(first).equals(hashFriendInviteToken(first)),true);
  assert.equal(isFriendInviteToken("short"),false);
});

test("friend pairs are canonical and reject self friendship", () => {
  assert.deepEqual(canonicalFriendPair("b","a"),["a","b"]);
  assert.throws(()=>canonicalFriendPair("a","a"),/another/);
});

test("public profile and share snapshot fields are bounded", () => {
  assert.equal(normalizedDisplayName("  Meg   Yang "),"Meg Yang");
  assert.throws(()=>normalizedDisplayName(""),/1–50/);
  assert.deepEqual(validateShareSnapshot({title:" Look ",rationale:"Why"}),{version:1,title:"Look",rationale:"Why"});
  assert.equal(validateShareSnapshot({title:"x".repeat(150)}).title.length,120);
  assert.throws(()=>validateShareSnapshot({}),/title/);
});

test("social migration keeps sharing explicit and private", () => {
  const migration = fs.readFileSync(new URL("../supabase/migrations/0003_private_social.sql",import.meta.url),"utf8").toLowerCase();
  for (const marker of ["friend_invites","friendships","blocks","outfit_shares","share_reactions","share_copies","activity_events","enable row level security","service_controls","consume_rate_limit"]) assert.match(migration,new RegExp(marker));
  assert.match(migration,/shares_participant_select/);
  assert.match(migration,/ai_enabled/);
  assert.match(migration,/monthly_ai_budget_usd/);
});

test("server authorizes social assets through share routes instead of public storage", () => {
  const source = fs.readFileSync(new URL("../server.mjs",import.meta.url),"utf8");
  assert.match(source,/usersAreBlocked/);
  assert.match(source,/areFriends/);
  assert.match(source,/signedDownload/);
  assert.match(source,/outfit-shares/);
  assert.doesNotMatch(source,/publicURL/);
});
