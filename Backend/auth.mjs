import { createRemoteJWKSet, jwtVerify } from "jose";

export function createAuthenticator({ supabaseURL, audience = "authenticated" }) {
  const jwks = createRemoteJWKSet(new URL(`${supabaseURL}/auth/v1/.well-known/jwks.json`));
  return async function authenticate(req) {
    const header = String(req.headers.authorization || "");
    if (!header.startsWith("Bearer ")) throw httpError(401, "Authentication required.");
    try {
      const { payload } = await jwtVerify(header.slice(7), jwks, { audience });
      if (!payload.sub) throw new Error("missing subject");
      return { id: payload.sub, email: typeof payload.email === "string" ? payload.email : null };
    } catch { throw httpError(401, "Session is invalid or expired."); }
  };
}

export function httpError(status, message, code = null) {
  const error = new Error(message); error.status = status; error.code = code; return error;
}

export async function requireActiveMember(db, user) {
  const { rows } = await db.query("select id, status from profiles where id = $1", [user.id]);
  if (!rows[0] || rows[0].status !== "active") throw httpError(403, "A valid Wearwell invitation is required.", "invite_required");
  return rows[0];
}
