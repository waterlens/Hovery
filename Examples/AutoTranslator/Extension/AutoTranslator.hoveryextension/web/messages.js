// The page's text comes from i18n.toml. Hovery passes it in the user's language as `extension.messages`.

import { TranslationError } from "./translator.js"

/**
 * Looks up messages by key. `text` replaces `{name}` placeholders with `values.name`; a message
 * that is missing shows its key. `list` joins items the way the extension's language does.
 */
export function createMessages(extension) {
  const messages = extension?.messages ?? {}
  const listFormat = new Intl.ListFormat(extension?.language ?? "en", { type: "conjunction" })
  return {
    text: (key, values) => format(messages[key] ?? key, values),
    list: items => listFormat.format(items)
  }
}

export function format(template, values = {}) {
  return template.replace(/\{(\w+)\}/g, (placeholder, name) => (
    values[name] === undefined ? placeholder : String(values[name])
  ))
}

/**
 * Explains a failed translation with a message and, when there is advice, a hint. The service's
 * own message is shown as it is; everything else comes from the messages named by the error's code.
 */
export function describeFailure(error, { text }) {
  if (!(error instanceof TranslationError)) {
    return { message: errorMessage(error) ?? text("unknown") }
  }
  const hint = hintKey(error)
  return {
    message: error.serviceMessage
      ?? errorMessage(error.cause)
      ?? text(error.code, { status: error.status, origin: error.origin, seconds: error.timeout }),
    hint: hint && text(hint)
  }
}

function hintKey({ code, status }) {
  switch (code) {
    case "invalidBaseURL":
      return "invalidBaseURLHint"
    case "timeout":
      return "timeoutHint"
    case "network":
      return "networkHint"
    case "http":
      if (status === 401 || status === 403) return "unauthorizedHint"
      if (status === 404) return "notFoundHint"
      if (status === 429) return "rateLimitedHint"
      if (status >= 500) return "serverErrorHint"
      return undefined
    default:
      return undefined
  }
}

function errorMessage(error) {
  const message = typeof error === "string" ? error : error?.message
  return typeof message === "string" && message ? message : undefined
}
