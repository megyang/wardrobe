import { httpError } from "./auth.mjs";

export async function readJSON(req, limit = 2 * 1024 * 1024) {
  const chunks = []; let size = 0;
  for await (const chunk of req) { size += chunk.length; if (size > limit) throw httpError(413, "Request is too large."); chunks.push(chunk); }
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw httpError(400, "Request body must be valid JSON."); }
}

export function send(res, status, value) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" });
  res.end(JSON.stringify(value));
}

export function routeID(pathname, prefix) {
  const match = pathname.match(new RegExp(`^${prefix}/([0-9a-f-]{36})$`, "i"));
  return match?.[1] || null;
}
