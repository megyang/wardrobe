import { randomUUID } from "node:crypto";
import { loadConfig } from "./config.mjs";
import { createDatabase } from "./database.mjs";
import { createStorage } from "./storage.mjs";
import { createOpenAIService } from "./openai-service.mjs";
import { createWorkflows } from "./workflows.mjs";

const config = loadConfig(); const db = createDatabase(config.databaseURL); const storage = createStorage(config);
const runWorkflow = createWorkflows({ db, storage, openai: createOpenAIService(config) });
const workerID = randomUUID(); let stopping = false;

async function runSlot(slot) {
  while (!stopping) {
    const { rows } = await db.query("select * from claim_job($1,$2)", [`${workerID}:${slot}`, config.leaseSeconds]);
    const job = rows[0];
    if (!job) { await delay(1000); continue; }
    const controller = new AbortController();
    const heartbeat = setInterval(async () => {
      const result = await db.query("update jobs set lease_expires_at=now()+make_interval(secs=>$3),updated_at=now() where id=$1 and lease_owner=$2 and state='processing' and cancel_requested_at is null", [job.id,`${workerID}:${slot}`,config.leaseSeconds]);
      if (!result.rowCount) controller.abort(new Error("Job lease lost or cancellation requested."));
    }, Math.max(10_000, config.leaseSeconds * 500));
    heartbeat.unref();
    try {
      const output = await runWorkflow(job, controller.signal);
      const estimatedCost = estimateCost(output.usage);
      await db.transaction(async client => {
        await client.query("update jobs set state='complete',stage='Complete',result=$2,model_version=$3,latency_ms=$4,usage=$5,estimated_cost_usd=$6,request=jsonb_build_object('completed',true),lease_owner=null,lease_expires_at=null,updated_at=now() where id=$1", [job.id,output.result,output.model,output.latencyMs,output.usage,estimatedCost]);
        await client.query("insert into usage_ledger (owner_id,job_id,kind,input_tokens,output_tokens,image_calls,latency_ms,model_version,estimated_cost_usd) values ($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict (job_id) do nothing", [job.owner_id,job.id,job.kind,output.usage?.inputTokens||0,output.usage?.outputTokens||0,output.usage?.imageCalls||0,output.latencyMs,output.model,estimatedCost]);
      });
    } catch (error) {
      const transient = /429|rate|timeout|temporar|ECONNRESET|5\d\d/i.test(error?.message || "");
      const retry = transient && Number(job.attempt_count) < 3;
      await db.query("update jobs set state=$2,stage=$3,error_code=$4,error_message=$5,request=case when $2='queued' then request else jsonb_build_object('failed',true) end,available_at=case when $2='queued' then now()+make_interval(secs=>least(300,30*attempt_count)) else available_at end,lease_owner=null,lease_expires_at=null,updated_at=now() where id=$1", [job.id,retry?"queued":controller.signal.aborted?"cancelled":"failed",retry?"Waiting to retry":"Failed",transient?"transient":"workflow_error",String(error?.message||error).slice(0,500)]);
    } finally { clearInterval(heartbeat); }
  }
}

async function purgeAccounts() {
  const { rows } = await db.query("select owner_id from deletion_requests where completed_at is null and purge_after<=now() limit 10");
  for (const request of rows) {
    const assets = await db.query("select storage_path from assets where owner_id=$1", [request.owner_id]);
    await storage.remove(assets.rows.map(row => row.storage_path));
    await db.query("select purge_account($1)", [request.owner_id]);
  }
}

const slots = Array.from({ length: config.workerConcurrency }, (_, index) => runSlot(index + 1));
const purgeTimer = setInterval(() => purgeAccounts().catch(error => console.error(JSON.stringify({ level: "error", message: "Account purge failed", detail: error.message }))), 60_000); purgeTimer.unref();
for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, () => { stopping = true; clearInterval(purgeTimer); });
await Promise.all(slots); await db.close();

function delay(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
function estimateCost(usage = {}) {
  return ((usage.inputTokens || 0) * config.inputCostPerMillion / 1_000_000) +
    ((usage.outputTokens || 0) * config.outputCostPerMillion / 1_000_000) +
    ((usage.imageCalls || 0) * config.imageCostPerCall);
}
