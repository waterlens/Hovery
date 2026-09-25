import assert from "node:assert/strict"
import { describe, test } from "node:test"

import { TranslationCache } from "../Extension/AutoTranslator.hoveryextension/web/translations.js"
import {
  EventStreamParser,
  TranslationError,
  buildMessages,
  chatCompletionsURL,
  translate,
  visibleText
} from "../Extension/AutoTranslator.hoveryextension/web/translator.js"

const encoder = new TextEncoder()

const baseOptions = {
  baseURL: "https://api.example.com/v1",
  apiKey: "test-key",
  model: "test-model",
  targetLanguage: "Simplified Chinese",
  alternateLanguage: "English",
  instructions: "",
  stream: true,
  timeout: 5,
  level: "sentence",
  text: "Hello world"
}

function streamedResponse(chunks, { onCancel, keepOpen = false } = {}) {
  const queue = [...chunks]
  const body = new ReadableStream({
    pull(controller) {
      if (queue.length > 0) {
        controller.enqueue(encoder.encode(queue.shift()))
      } else if (!keepOpen) {
        controller.close()
      }
    },
    cancel() {
      onCancel?.()
    }
  })
  return new Response(body, { headers: { "content-type": "text/event-stream" } })
}

function deltaEvent(content) {
  return `data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`
}

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" }
  })
}

function abortableFetch() {
  return (_url, init) => new Promise((_resolve, reject) => {
    init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true })
  })
}

describe("chatCompletionsURL", () => {
  test("appends the Chat Completions path to a base URL", () => {
    assert.equal(chatCompletionsURL("https://api.openai.com/v1"), "https://api.openai.com/v1/chat/completions")
    assert.equal(chatCompletionsURL(" http://localhost:11434/v1/ "), "http://localhost:11434/v1/chat/completions")
  })

  test("accepts a complete endpoint", () => {
    assert.equal(
      chatCompletionsURL("https://example.com/api/v1/chat/completions"),
      "https://example.com/api/v1/chat/completions"
    )
  })

  test("rejects values that are not http or https URLs", () => {
    for (const value of ["api.openai.com/v1", "", "ftp://example.com/v1"]) {
      assert.throws(() => chatCompletionsURL(value), error => {
        assert.ok(error instanceof TranslationError)
        assert.equal(error.kind, "configuration")
        return true
      })
    }
  })
})

describe("buildMessages", () => {
  test("translates sentences and falls back to the alternate language", () => {
    const [system, user] = buildMessages(baseOptions)
    assert.equal(system.role, "system")
    assert.match(system.content, /Translate the user's message into Simplified Chinese\./)
    assert.match(system.content, /translate it into English instead/)
    assert.deepEqual(user, { role: "user", content: "Hello world" })
  })

  test("uses dictionary rules for words", () => {
    const [system] = buildMessages({ ...baseOptions, level: "word", text: "hover" })
    assert.match(system.content, /dictionary engine/)
    assert.match(system.content, /part of speech/)
  })

  test("omits the alternate language when it matches the target", () => {
    const [system] = buildMessages({ ...baseOptions, alternateLanguage: "Simplified Chinese" })
    assert.doesNotMatch(system.content, /instead/)
  })

  test("appends additional instructions", () => {
    const [system] = buildMessages({ ...baseOptions, instructions: "  Keep technical terms in English.\n" })
    assert.match(system.content, /Additional instructions:\nKeep technical terms in English\.$/)
  })

  test("limits very long input", () => {
    const [, user] = buildMessages({ ...baseOptions, text: "a".repeat(6000) })
    assert.equal(user.content.length, 5001)
    assert.ok(user.content.endsWith("…"))
  })
})

describe("EventStreamParser", () => {
  test("reassembles events split across chunks", () => {
    const parser = new EventStreamParser()
    assert.deepEqual(parser.push("data: {\"a\""), [])
    assert.deepEqual(parser.push(":1}\n"), [])
    assert.deepEqual(parser.push("\ndata: [DONE]\n\n"), ["{\"a\":1}", "[DONE]"])
  })

  test("handles CRLF, comments, and multi-line data", () => {
    const parser = new EventStreamParser()
    const events = parser.push(": keep-alive\r\n\r\nevent: message\r\ndata: first\r\ndata:second\r\n\r\n")
    assert.deepEqual(events, ["first\nsecond"])
  })

  test("flushes a final event without a trailing blank line", () => {
    const parser = new EventStreamParser()
    assert.deepEqual(parser.push("data: last"), [])
    assert.deepEqual(parser.finish(), ["last"])
  })
})

describe("visibleText", () => {
  test("hides reasoning blocks", () => {
    assert.equal(visibleText("<think>Considering…</think>\n\n你好"), "你好")
    assert.equal(visibleText("<think>Still thinking"), "")
    assert.equal(visibleText("Hello"), "Hello")
  })
})

describe("translate", () => {
  test("streams a translation from an OpenAI-compatible service", async () => {
    let request
    const updates = []
    const text = await translate(baseOptions, {
      onText: value => updates.push(value),
      fetch: async (url, init) => {
        request = { url, init }
        return streamedResponse([
          ": keep-alive\n\n",
          deltaEvent("你"),
          deltaEvent("好，"),
          `${deltaEvent("世界")}data: [DONE]\n\n`
        ])
      }
    })

    assert.equal(text, "你好，世界")
    assert.deepEqual(updates, ["你", "你好，", "你好，世界"])
    assert.equal(request.url, "https://api.example.com/v1/chat/completions")
    assert.equal(request.init.method, "POST")
    assert.equal(request.init.headers.Authorization, "Bearer test-key")
    const body = JSON.parse(request.init.body)
    assert.equal(body.model, "test-model")
    assert.equal(body.stream, true)
    assert.equal(body.messages.at(-1).content, "Hello world")
  })

  test("stops reading once the stream reports [DONE]", { timeout: 2000 }, async () => {
    let cancelled = false
    const text = await translate(baseOptions, {
      fetch: async () => streamedResponse([`${deltaEvent("Done")}data: [DONE]\n\n`], {
        keepOpen: true,
        onCancel: () => { cancelled = true }
      })
    })
    assert.equal(text, "Done")
    // Cancellation reaches the response body through the decoding pipe asynchronously.
    await new Promise(resolve => setTimeout(resolve, 10))
    assert.ok(cancelled)
  })

  test("reads a complete JSON response", async () => {
    let request
    const text = await translate({ ...baseOptions, apiKey: "", stream: false }, {
      fetch: async (url, init) => {
        request = init
        return jsonResponse({ choices: [{ message: { content: "  <think>hmm</think>你好  " } }] })
      }
    })
    assert.equal(text, "你好")
    assert.equal(request.headers.Authorization, undefined)
    assert.equal(JSON.parse(request.body).stream, false)
  })

  test("reports the service's error message with a hint", async () => {
    await assert.rejects(
      translate(baseOptions, {
        fetch: async () => jsonResponse({ error: { message: "Incorrect API key provided." } }, 401)
      }),
      error => {
        assert.ok(error instanceof TranslationError)
        assert.equal(error.kind, "http")
        assert.equal(error.status, 401)
        assert.equal(error.message, "Incorrect API key provided.")
        assert.match(error.hint, /API key/)
        return true
      }
    )
  })

  test("does not show HTML error pages", async () => {
    await assert.rejects(
      translate(baseOptions, {
        fetch: async () => new Response("<html><body>Not Found</body></html>", { status: 404 })
      }),
      error => {
        assert.equal(error.message, "The service responded with HTTP 404.")
        assert.match(error.hint, /\/v1/)
        return true
      }
    )
  })

  test("reports errors sent inside a stream", async () => {
    await assert.rejects(
      translate(baseOptions, {
        fetch: async () => streamedResponse([
          deltaEvent("Partial"),
          `data: ${JSON.stringify({ error: { message: "Model overloaded." } })}\n\n`
        ])
      }),
      { name: "TranslationError", message: "Model overloaded." }
    )
  })

  test("explains connection failures", async () => {
    await assert.rejects(
      translate(baseOptions, {
        fetch: async () => { throw new TypeError("Load failed") }
      }),
      error => {
        assert.equal(error.kind, "network")
        assert.equal(error.message, "Could not connect to https://api.example.com.")
        return true
      }
    )
  })

  test("times out when the service stops responding", async () => {
    await assert.rejects(
      translate({ ...baseOptions, timeout: 0.05 }, { fetch: abortableFetch() }),
      error => {
        assert.equal(error.kind, "timeout")
        return true
      }
    )
  })

  test("rejects with the caller's abort reason", async () => {
    const controller = new AbortController()
    const translation = translate(baseOptions, { signal: controller.signal, fetch: abortableFetch() })
    controller.abort()
    await assert.rejects(translation, { name: "AbortError" })
  })
})

describe("TranslationCache", () => {
  function deferredPerform() {
    const calls = []
    const perform = (request, { signal, onText }) => new Promise((resolve, reject) => {
      const call = { request, signal, onText, resolve, reject }
      calls.push(call)
      signal.addEventListener("abort", () => reject(signal.reason), { once: true })
    })
    return { calls, perform }
  }

  const request = { ...baseOptions }

  test("remembers finished translations", async () => {
    let count = 0
    const cache = new TranslationCache({
      perform: async ({ text }) => {
        count += 1
        return `translated ${text}`
      }
    })
    assert.equal(await cache.translate(request), "translated Hello world")
    assert.equal(await cache.translate({ ...request }), "translated Hello world")
    assert.equal(count, 1)
    assert.equal(await cache.translate({ ...request, targetLanguage: "Japanese" }), "translated Hello world")
    assert.equal(count, 2)
  })

  test("lets a new presentation follow a request that is still running", async () => {
    const { calls, perform } = deferredPerform()
    const cache = new TranslationCache({ perform })
    const firstPresentation = new AbortController()
    const firstUpdates = []
    const first = cache.translate(request, {
      signal: firstPresentation.signal,
      onText: text => firstUpdates.push(text)
    })
    await Promise.resolve()
    calls[0].onText("Partial")

    // Moving to another word of the same sentence aborts the first presentation.
    firstPresentation.abort()
    await assert.rejects(first, { name: "AbortError" })
    const secondUpdates = []
    const second = cache.translate(request, { onText: text => secondUpdates.push(text) })
    calls[0].onText("Partial result")
    calls[0].resolve("Complete result")

    assert.equal(await second, "Complete result")
    assert.equal(calls.length, 1)
    assert.equal(calls[0].signal.aborted, false)
    assert.deepEqual(firstUpdates, ["Partial"])
    assert.deepEqual(secondUpdates, ["Partial", "Partial result"])
  })

  test("cancels the running request when other text needs translating", async () => {
    const { calls, perform } = deferredPerform()
    const cache = new TranslationCache({ perform })
    const first = cache.translate(request)
    await Promise.resolve()
    const second = cache.translate({ ...request, text: "Goodbye" })
    await assert.rejects(first, { name: "AbortError" })
    assert.equal(calls[0].signal.aborted, true)
    calls[1].resolve("再见")
    assert.equal(await second, "再见")
  })

  test("does not send a request that is superseded during the delay", async () => {
    const { calls, perform } = deferredPerform()
    const cache = new TranslationCache({ perform, delay: 30 })
    const presentation = new AbortController()
    const translation = cache.translate(request, { signal: presentation.signal })
    presentation.abort()
    await assert.rejects(translation, { name: "AbortError" })
    await new Promise(resolve => setTimeout(resolve, 50))
    assert.equal(calls.length, 0)
  })

  test("retries failed translations and evicts old results", async () => {
    let attempts = 0
    const cache = new TranslationCache({
      capacity: 1,
      perform: async ({ text }) => {
        attempts += 1
        if (attempts === 1) throw new TranslationError("Temporary failure")
        return text.toUpperCase()
      }
    })
    await assert.rejects(cache.translate(request), { message: "Temporary failure" })
    assert.equal(await cache.translate(request), "HELLO WORLD")
    assert.equal(await cache.translate({ ...request, text: "other" }), "OTHER")
    assert.equal(await cache.translate(request), "HELLO WORLD")
    assert.equal(attempts, 4)
  })
})
