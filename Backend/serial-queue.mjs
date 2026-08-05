export class SerialQueue {
  #tail = Promise.resolve();

  run(operation) {
    const result = this.#tail.then(operation);
    this.#tail = result.catch(() => undefined);
    return result;
  }
}
