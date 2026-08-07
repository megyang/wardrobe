import crypto from "node:crypto";
import { createDatabase } from "../database.mjs";

const databaseURL = process.env.DATABASE_URL;
if (!databaseURL) throw new Error("Set DATABASE_URL in the shell or managed one-off job environment.");
const [command,...args] = process.argv.slice(2); const db = createDatabase(databaseURL);

try {
  if (command === "invite") {
    const [code,maxUsesValue="1",daysValue="30"] = args;
    if (!/^[A-Za-z0-9-]{6,64}$/.test(code || "")) throw new Error("Usage: npm run admin -- invite BETA-CODE [maxUses] [days]");
    const maxUses = positiveInteger(maxUsesValue,"maxUses"); const days = positiveInteger(daysValue,"days");
    const digest = crypto.createHash("sha256").update(code.toLowerCase()).digest();
    const { rows } = await db.query("insert into invite_codes(code_hash,label,max_uses,expires_at) values($1,$2,$3,now()+make_interval(days=>$4)) returning id,label,max_uses,expires_at",[digest,`Admin ${new Date().toISOString()}`,maxUses,days]);
    console.log(JSON.stringify(rows[0],null,2));
  } else if (command === "ai") {
    const enabled = args[0] === "on" ? true : args[0] === "off" ? false : null;
    if (enabled === null) throw new Error("Usage: npm run admin -- ai on|off");
    const { rows } = await db.query("update service_controls set ai_enabled=$1,updated_at=now() where singleton=true returning ai_enabled,monthly_ai_budget_usd,updated_at",[enabled]);
    console.log(JSON.stringify(rows[0],null,2));
  } else if (command === "budget") {
    const budget = Number(args[0]); if (!Number.isFinite(budget) || budget < 0) throw new Error("Usage: npm run admin -- budget <monthly-usd>");
    const { rows } = await db.query("update service_controls set monthly_ai_budget_usd=$1,updated_at=now() where singleton=true returning ai_enabled,monthly_ai_budget_usd,updated_at",[budget]);
    console.log(JSON.stringify(rows[0],null,2));
  } else if (command === "suspend") {
    if (!/^[0-9a-f-]{36}$/i.test(args[0] || "")) throw new Error("Usage: npm run admin -- suspend <user-uuid>");
    const { rows } = await db.query("update profiles set status='suspended',updated_at=now() where id=$1 returning id,status,updated_at",[args[0]]);
    if (!rows[0]) throw new Error("User not found."); console.log(JSON.stringify(rows[0],null,2));
  } else {
    throw new Error("Commands: invite, ai, budget, suspend");
  }
} finally { await db.close(); }

function positiveInteger(value,label) { const parsed=Number(value); if (!Number.isSafeInteger(parsed)||parsed<1) throw new Error(`${label} must be a positive integer.`); return parsed; }
