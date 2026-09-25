// Hovery presents the same sentence again whenever the pointer moves to another word inside it.
// This cache lets those presentations share one request and remembers recent translations.

export class TranslationCache {
  #results = new Map()
  #active = null

  /**
   * `perform(request, { signal, onText })` performs one translation. `delay` postpones new
   * requests so that sweeping the pointer across text does not send a request for every stop.
   */
  constructor({ perform, capacity = 200, delay = 0 }) {
    this.perform = perform
    this.capacity = capacity
    this.delay = delay
  }

  /**
   * Resolves with the translation of `request`. Aborting `signal` only stops this caller from
   * following the result; the request continues so that its result can be reused, until another
   * text needs translating.
   */
  async translate(request, { signal, onText } = {}) {
    const key = cacheKey(request)
    if (this.#results.has(key)) {
      const text = this.#results.get(key)
      this.#results.delete(key)
      this.#results.set(key, text)
      return text
    }
    if (this.#active?.key !== key) {
      await wait(this.delay, signal)
      if (this.#active?.key !== key) {
        this.#start(key, request)
      }
    }
    return follow(this.#active, signal, onText)
  }

  cancel() {
    this.#active?.controller.abort()
    this.#active = null
  }

  #start(key, request) {
    this.#active?.controller.abort()
    const job = { key, controller: new AbortController(), text: "", listeners: new Set() }
    job.promise = this.perform(request, {
      signal: job.controller.signal,
      onText: text => {
        job.text = text
        for (const listener of job.listeners) listener(text)
      }
    })
      .then(text => {
        this.#remember(key, text)
        return text
      })
      .finally(() => {
        if (this.#active === job) this.#active = null
      })
    // Failures are reported to followers; a job nobody follows anymore must not be unhandled.
    job.promise.catch(() => {})
    this.#active = job
  }

  #remember(key, text) {
    this.#results.set(key, text)
    while (this.#results.size > this.capacity) {
      this.#results.delete(this.#results.keys().next().value)
    }
  }
}

function cacheKey({ baseURL, model, targetLanguage, alternateLanguage, instructions, level, text }) {
  return JSON.stringify([baseURL, model, targetLanguage, alternateLanguage, instructions, level, text])
}

function follow(job, signal, onText) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason)
      return
    }
    const listener = text => onText?.(text)
    const cleanup = () => {
      job.listeners.delete(listener)
      signal?.removeEventListener("abort", abort)
    }
    const abort = () => {
      cleanup()
      reject(signal.reason)
    }
    job.listeners.add(listener)
    signal?.addEventListener("abort", abort, { once: true })
    if (job.text) listener(job.text)
    job.promise.then(
      text => {
        cleanup()
        resolve(text)
      },
      error => {
        cleanup()
        reject(error)
      }
    )
  })
}

function wait(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason)
      return
    }
    if (milliseconds <= 0) {
      resolve()
      return
    }
    const abort = () => {
      clearTimeout(timer)
      reject(signal.reason)
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", abort)
      resolve()
    }, milliseconds)
    signal?.addEventListener("abort", abort, { once: true })
  })
}
