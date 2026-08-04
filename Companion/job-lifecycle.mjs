export const JOB_TTL_MS = 24 * 60 * 60 * 1000;
export const QUEUED_JOB_TTL_MS = 24 * 60 * 60 * 1000;
export const PROCESSING_TIMEOUT_MS = 60 * 60 * 1000;

export function isAnalysisJobOverdue(job, now = Date.now()) {
  if (job.state === "queued") return now - Date.parse(job.queuedAt || job.createdAt) >= QUEUED_JOB_TTL_MS;
  if (job.state === "processing") return now - Date.parse(job.processingStartedAt || job.updatedAt) >= PROCESSING_TIMEOUT_MS;
  return false;
}
