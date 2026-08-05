import { randomUUID } from "node:crypto";

const baseURL = process.env.STAGING_API_URL;
const users = { a: process.env.STAGING_USER_A_TOKEN, b: process.env.STAGING_USER_B_TOKEN };
if (!baseURL || !users.a || !users.b) throw new Error("Set STAGING_API_URL, STAGING_USER_A_TOKEN, and STAGING_USER_B_TOKEN.");

const recordID = randomUUID();
let remoteAssetID;

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
  console.log("Staging isolation smoke test passed for two active beta accounts.");
} finally {
  await call(users.a, `/v1/data/garments/${recordID}`, { method: "DELETE", expected: 204, returnError: true });
  if (remoteAssetID) await call(users.a, `/v1/assets/${remoteAssetID}`, { method: "DELETE", expected: 204, returnError: true });
}

async function call(token, path, options = {}) {
  const response = await fetch(new URL(path, baseURL), {
    method: options.method || "GET",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: options.body ? JSON.stringify(options.body) : undefined
  });
  const expected = options.expected || 200;
  const data = response.status === 204 ? {} : await response.json().catch(() => ({}));
  if (response.status !== expected && !options.returnError) throw new Error(`${path}: expected ${expected}, received ${response.status}: ${data.error || "unknown error"}`);
  return options.returnError ? { status: response.status, data } : data;
}

function assert(condition, message) { if (!condition) throw new Error(message); }
