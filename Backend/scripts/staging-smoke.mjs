import { createHash, randomUUID } from "node:crypto";

const baseURL = process.env.STAGING_API_URL;
const users = { a: process.env.STAGING_USER_A_TOKEN, b: process.env.STAGING_USER_B_TOKEN };
if (!baseURL || !users.a || !users.b) throw new Error("Set STAGING_API_URL, STAGING_USER_A_TOKEN, and STAGING_USER_B_TOKEN.");

const recordID = randomUUID();
let remoteAssetID;
let shareID;
let userBID;

try {
  await call(users.a, `/v1/data/garments/${recordID}`, { method: "PUT", body: { revision: 0, data: { label: "Isolation probe", probe: recordID } }, expected: 201 });
  const aRecords = await call(users.a, "/v1/data/garments");
  const bRecords = await call(users.b, "/v1/data/garments");
  assert(aRecords.records.some(record => record.id === recordID), "User A cannot read its probe record.");
  assert(!bRecords.records.some(record => record.id === recordID), "Cross-user record leak detected.");

  const assetProbe = await call(users.a, "/v1/assets/upload", {
    method: "POST", expected: 201,
    body: { mimeType: "image/png", byteCount: 1, sha256: "0".repeat(64), kind: "staging-probe" }
  });
  remoteAssetID = assetProbe.assetID;
  const leaked = await call(users.b, `/v1/assets/${assetProbe.assetID}`, { expected: 404, returnError: true });
  assert(leaked.status === 404, "Cross-user signed asset URL leak detected.");

  await call(users.a, "/v1/usage");
  await call(users.b, "/v1/usage");
  await call(users.a,"/v1/profile",{method:"PUT",body:{displayName:"Staging A"}});
  userBID = (await call(users.b,"/v1/profile",{method:"PUT",body:{displayName:"Staging B"}})).id;
  const invitation = await call(users.a,"/v1/friend-invites",{method:"POST",expected:201});
  const redemption = await call(users.b,"/v1/friend-invites/redeem",{method:"POST",body:{token:invitation.token}});
  const friendID = redemption.friend.id;
  const bFriends = await call(users.b,"/v1/friends");
  assert(bFriends.friends.some(friend=>friend.id===friendID),"Friend invitation did not create an accepted friendship.");

  const preview = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=","base64");
  const declared = await call(users.a,"/v1/assets/upload",{method:"POST",expected:201,body:{mimeType:"image/png",byteCount:preview.length,sha256:createHash("sha256").update(preview).digest("hex"),kind:"staging-share"}});
  remoteAssetID = declared.assetID;
  if (!declared.alreadyUploaded) {
    const upload = await fetch(declared.signedUrl,{method:"PUT",headers:{"content-type":"image/png"},body:preview});
    assert(upload.ok,"Signed staging preview upload failed.");
    await call(users.a,"/v1/assets/finalize",{method:"POST",body:{assetID:remoteAssetID}});
  }
  const share = await call(users.a,"/v1/shares",{method:"POST",expected:201,headers:{"Idempotency-Key":randomUUID()},body:{recipientID:userBID,previewAssetID:remoteAssetID,snapshot:{title:"Staging look",rationale:"Private share probe"}}});
  shareID = share.id;
  const detail = await call(users.b,`/v1/shares/${shareID}`);
  assert(detail.snapshot.title==="Staging look" && detail.previewURL,"Recipient could not open its private share.");
  const leakedShare = await call(users.a,`/v1/shares/${randomUUID()}`,{expected:404,returnError:true});
  assert(leakedShare.status===404,"Unknown share did not fail closed.");
  await call(users.b,`/v1/shares/${shareID}/reaction`,{method:"PUT",body:{}});
  console.log("Staging isolation and private friend-sharing smoke test passed for two active beta accounts.");
} finally {
  if (shareID) await call(users.a,`/v1/shares/${shareID}`,{method:"DELETE",expected:204,returnError:true});
  if (userBID) await call(users.a,`/v1/friends/${userBID}`,{method:"DELETE",expected:204,returnError:true});
  await call(users.a, `/v1/data/garments/${recordID}`, { method: "DELETE", expected: 204, returnError: true });
  if (remoteAssetID) await call(users.a, `/v1/assets/${remoteAssetID}`, { method: "DELETE", expected: 204, returnError: true });
}

async function call(token, path, options = {}) {
  const response = await fetch(new URL(path, baseURL), {
    method: options.method || "GET",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...(options.headers || {}) },
    body: options.body ? JSON.stringify(options.body) : undefined
  });
  const expected = options.expected || 200;
  const data = response.status === 204 ? {} : await response.json().catch(() => ({}));
  if (response.status !== expected && !options.returnError) throw new Error(`${path}: expected ${expected}, received ${response.status}: ${data.error || "unknown error"}`);
  return options.returnError ? { status: response.status, data } : data;
}

function assert(condition, message) { if (!condition) throw new Error(message); }
