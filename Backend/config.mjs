const required = ["DATABASE_URL", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "OPENAI_API_KEY"];

export function loadConfig(env = process.env) {
  const missing = required.filter(key => !env[key]);
  if (missing.length) throw new Error(`Missing required environment variables: ${missing.join(", ")}`);
  return Object.freeze({
    environment: env.NODE_ENV || "development",
    port: Number(env.PORT || 8791),
    databaseURL: env.DATABASE_URL,
    supabaseURL: env.SUPABASE_URL,
    supabaseAnonKey: env.SUPABASE_ANON_KEY || "",
    supabaseServiceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY,
    openAIKey: env.OPENAI_API_KEY,
    textModel: env.OPENAI_TEXT_MODEL || "gpt-5.6-luna",
    imageModel: env.OPENAI_IMAGE_MODEL || "gpt-image-2",
    publicURL: env.API_PUBLIC_URL || `http://127.0.0.1:${Number(env.PORT || 8791)}`,
    workerConcurrency: Math.max(1, Math.min(8, Number(env.WORKER_CONCURRENCY || 2))),
    leaseSeconds: Math.max(30, Number(env.JOB_LEASE_SECONDS || 120)),
    inputCostPerMillion: Math.max(0, Number(env.OPENAI_INPUT_COST_PER_MILLION || 0)),
    outputCostPerMillion: Math.max(0, Number(env.OPENAI_OUTPUT_COST_PER_MILLION || 0)),
    imageCostPerCall: Math.max(0, Number(env.OPENAI_IMAGE_COST_PER_CALL || 0))
  });
}
