export async function withAbortTimeout(milliseconds, message, operation, parentSignal = null) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), milliseconds);
  const abortFromParent = () => controller.abort(parentSignal?.reason);
  if (parentSignal?.aborted) abortFromParent();
  else parentSignal?.addEventListener("abort", abortFromParent, { once: true });
  try {
    return await operation(controller.signal);
  } catch (error) {
    if (parentSignal?.aborted) {
      throw parentSignal.reason instanceof Error ? parentSignal.reason : new Error("Operation cancelled.", { cause: error });
    }
    if (controller.signal.aborted) throw new Error(message, { cause: error });
    throw error;
  } finally {
    clearTimeout(timer);
    parentSignal?.removeEventListener("abort", abortFromParent);
  }
}
