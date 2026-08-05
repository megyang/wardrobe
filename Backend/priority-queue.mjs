export class PriorityQueue {
  #pending = new Map();
  #active = new Map();
  #availableSlots;
  #sequence = 0;

  constructor(worker, concurrency = 1) {
    if (!Number.isInteger(concurrency) || concurrency < 1) throw new Error("Queue concurrency must be a positive integer.");
    this.worker = worker;
    this.concurrency = concurrency;
    this.#availableSlots = Array.from({ length: concurrency }, (_, index) => index);
  }

  enqueue(key, priority = 0) {
    const existing = this.#pending.get(key);
    if (!existing || priority > existing.priority) {
      this.#pending.set(key, { key, priority, sequence: existing?.sequence ?? this.#sequence++ });
    }
    void this.#drain();
  }

  position(key) {
    const ordered = [...this.#pending.values()].sort((a, b) => b.priority - a.priority || a.sequence - b.sequence);
    const index = ordered.findIndex(item => item.key === key);
    return index < 0 ? null : index + 1;
  }

  cancel(key) { return this.#pending.delete(key); }

  #drain() {
    while (this.#pending.size && this.#availableSlots.length) {
      const next = [...this.#pending.values()].sort((a, b) => b.priority - a.priority || a.sequence - b.sequence)[0];
      const slot = this.#availableSlots.shift();
      this.#pending.delete(next.key);
      this.#active.set(next.key, slot);
      Promise.resolve()
        .then(() => this.worker(next.key, slot))
        .catch(error => console.error("Queued operation failed", next.key, error))
        .finally(() => {
          this.#active.delete(next.key);
          this.#availableSlots.push(slot);
          this.#availableSlots.sort((a, b) => a - b);
          this.#drain();
        });
    }
  }
}
