import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import { describe, test } from "node:test"

import { createMessages, describeFailure, format } from "../Extension/AutoTranslator.hoveryextension/web/messages.js"
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
const packageURL = new URL("../Extension/AutoTranslator.hoveryextension/", import.meta.url)

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

async function rejectsWith(promise, expected) {
  await assert.rejects(promise, error => {
    assert.ok(error instanceof TranslationError)
    for (const [key, value] of Object.entries(expected)) {
      assert.deepEqual(error[key], value, key)
    }
    return true
  })
}

/** Reads the messages of `language` from i18n.toml, which uses only one-line strings. */
async function packageMessages(language) {
  const source = await readFile(new URL("i18n.toml", packageURL), "utf8")
  const messages = {}
  let section
  for (const line of source.split("\n")) {
    const header = line.match(/^\[(.+)\]$/)
    const entry = line.match(/^(\w+) = (".*")$/)
    if (header) {
      section = header[1]
    } else if (entry && section === `${language}.messages`) {
      messages[entry[1]] = JSON.parse(entry[2])
    }
  }
  return messages
}

/** The keys that `pattern`'s first group captures in a file of the package's web directory. */
async function sourceKeys(file, pattern) {
  const source = await readFile(new URL(`web/${file}`, packageURL), "utf8")
  return [...source.matchAll(pattern)].map(match => match[1])
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
    const cases = [
      ["api.openai.com/v1", "invalidBaseURL"],
      ["", "invalidBaseURL"],
      ["ftp://example.com/v1", "unsupportedBaseURL"]
    ]
    for (const [value, code] of cases) {
      assert.throws(() => chatCompletionsURL(value), error => {
        assert.ok(error instanceof TranslationError)
        assert.equal(error.code, code)
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

  test("reports the service's error message with the HTTP status", async () => {
    await rejectsWith(
      translate(baseOptions, {
        fetch: async () => jsonResponse({ error: { message: "Incorrect API key provided." } }, 401)
      }),
      { code: "http", status: 401, serviceMessage: "Incorrect API key provided." }
    )
  })

  test("does not show HTML error pages", async () => {
    await rejectsWith(
      translate(baseOptions, {
        fetch: async () => new Response("<html><body>Not Found</body></html>", { status: 404 })
      }),
      { code: "http", status: 404, serviceMessage: undefined }
    )
  })

  test("reports plain-text error bodies", async () => {
    await rejectsWith(
      translate(baseOptions, {
        fetch: async () => new Response("  Rate limit exceeded  ", { status: 429 })
      }),
      { code: "http", status: 429, serviceMessage: "Rate limit exceeded" }
    )
  })

  test("reports errors sent inside a stream", async () => {
    await rejectsWith(
      translate(baseOptions, {
        fetch: async () => streamedResponse([
          deltaEvent("Partial"),
          `data: ${JSON.stringify({ error: { message: "Model overloaded." } })}\n\n`
        ])
      }),
      { name: "TranslationError", code: "serviceError", serviceMessage: "Model overloaded." }
    )
  })

  test("reports errors in a complete response, even without a message", async () => {
    await rejectsWith(
      translate({ ...baseOptions, stream: false }, { fetch: async () => jsonResponse({ error: {} }) }),
      { code: "serviceError", serviceMessage: undefined }
    )
  })

  test("reports malformed, unexpected, and empty responses", async () => {
    await rejectsWith(
      translate(baseOptions, { fetch: async () => streamedResponse(["data: {not json\n\n"]) }),
      { code: "malformedStream" }
    )
    await rejectsWith(
      translate({ ...baseOptions, stream: false }, { fetch: async () => jsonResponse({ choices: [] }) }),
      { code: "unexpectedResponse" }
    )
    await rejectsWith(
      translate(baseOptions, { fetch: async () => streamedResponse([deltaEvent("<think>Hmm</think>  ")]) }),
      { code: "emptyTranslation" }
    )
  })

  test("explains connection failures", async () => {
    await rejectsWith(
      translate(baseOptions, {
        fetch: async () => { throw new TypeError("Load failed") }
      }),
      { code: "network", origin: "https://api.example.com" }
    )
  })

  test("keeps unexpected failures as the cause", async () => {
    const cause = new RangeError("Unexpected failure")
    await rejectsWith(
      translate(baseOptions, { fetch: async () => { throw cause } }),
      { code: "unknown", cause }
    )
  })

  test("times out when the service stops responding", async () => {
    await rejectsWith(
      translate({ ...baseOptions, timeout: 0.05 }, { fetch: abortableFetch() }),
      { code: "timeout", timeout: 0.05 }
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
        if (attempts === 1) throw new TranslationError("http", { status: 503 })
        return text.toUpperCase()
      }
    })
    await assert.rejects(cache.translate(request), { code: "http", status: 503 })
    assert.equal(await cache.translate(request), "HELLO WORLD")
    assert.equal(await cache.translate({ ...request, text: "other" }), "OTHER")
    assert.equal(await cache.translate(request), "HELLO WORLD")
    assert.equal(attempts, 4)
  })
})

describe("messages", () => {
  test("fills in placeholders and keeps unknown ones", () => {
    assert.equal(format("{status} of {total}", { status: 404 }), "404 of {total}")
    assert.equal(format("No placeholders"), "No placeholders")
  })

  test("looks up messages and lists in the extension's language", () => {
    const chinese = createMessages({ language: "zh-Hans", messages: { greeting: "你好，{name}" } })
    assert.equal(chinese.text("greeting", { name: "Hovery" }), "你好，Hovery")
    assert.equal(chinese.text("missing"), "missing")
    assert.equal(chinese.list(["“API 地址”", "“模型”"]), "“API 地址”和“模型”")

    const english = createMessages(undefined)
    assert.equal(english.text("copied"), "copied")
    assert.equal(english.list(["Base URL", "Model"]), "Base URL and Model")
  })

  test("describes each failure with the package's messages", async () => {
    const messages = createMessages({ language: "en", messages: await packageMessages("en") })
    const explain = error => describeFailure(error, messages)

    assert.deepEqual(explain(new TranslationError("invalidBaseURL")), {
      message: "The Base URL is not a valid URL.",
      hint: "Enter a full URL, such as https://api.openai.com/v1."
    })
    assert.deepEqual(explain(new TranslationError("unsupportedBaseURL")), {
      message: "The Base URL must start with https:// or http://.",
      hint: undefined
    })
    assert.deepEqual(explain(new TranslationError("timeout", { timeout: 30 })), {
      message: "The service did not respond within 30 seconds.",
      hint: "Try again, or increase the timeout in Auto Translator’s settings."
    })
    assert.deepEqual(explain(new TranslationError("network", { origin: "https://api.example.com" })), {
      message: "Could not connect to https://api.example.com.",
      hint: "Check the Base URL and your network connection. The service must allow cross-origin requests (CORS)."
    })
    assert.deepEqual(
      explain(new TranslationError("http", { status: 401, serviceMessage: "Incorrect API key provided." })),
      { message: "Incorrect API key provided.", hint: "Check the API key in Auto Translator’s settings." }
    )
    assert.deepEqual(explain(new TranslationError("http", { status: 404 })), {
      message: "The service responded with HTTP 404.",
      hint: "Check the Base URL (it usually ends with a version path such as /v1) and the model name."
    })
    assert.equal(explain(new TranslationError("http", { status: 403 })).hint, "Check the API key in Auto Translator’s settings.")
    assert.equal(explain(new TranslationError("http", { status: 429 })).hint, "The service is limiting requests. Try again in a moment.")
    assert.equal(explain(new TranslationError("http", { status: 503 })).hint, "The service had a problem. Try again later.")
    assert.equal(explain(new TranslationError("http", { status: 400 })).hint, undefined)
    assert.equal(explain(new TranslationError("serviceError")).message, "The service reported an error.")
    assert.equal(
      explain(new TranslationError("serviceError", { serviceMessage: "Model overloaded." })).message,
      "Model overloaded."
    )
    assert.equal(explain(new TranslationError("malformedStream")).message, "The service sent a malformed streaming response.")
    assert.equal(explain(new TranslationError("unexpectedResponse")).message, "The service returned an unexpected response.")
    assert.equal(explain(new TranslationError("emptyTranslation")).message, "The service returned an empty translation.")
    assert.equal(explain(new TranslationError("unknown", { cause: new RangeError("Out of range") })).message, "Out of range")
    assert.equal(explain(new TranslationError("unknown")).message, "An unknown error occurred.")
    assert.deepEqual(explain(new TypeError("Load failed")), { message: "Load failed" })
    assert.deepEqual(explain(undefined), { message: "An unknown error occurred." })
  })

  test("exist in English and Simplified Chinese for all text the page shows", async () => {
    const english = await packageMessages("en")
    const chinese = await packageMessages("zh-Hans")
    assert.deepEqual(Object.keys(chinese).sort(), Object.keys(english).sort())

    const pageKeys = await sourceKeys("main.js", /\btext\("(\w+)"/g)
    const codes = await sourceKeys("translator.js", /new TranslationError\("(\w+)"/g)
    assert.ok(pageKeys.includes("setupRequired") && codes.includes("timeout"))
    for (const key of [...pageKeys, ...codes, "unknown"]) {
      assert.ok(key in english, `${key} has no English message`)
    }
  })
})
