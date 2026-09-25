import { createMessages, describeFailure } from "./messages.js"
import { TranslationCache } from "./translations.js"
import { translate } from "./translator.js"

const requestDelay = 150
const copiedFeedbackDuration = 1200
const svgNamespace = "http://www.w3.org/2000/svg"

const highlightStyle = {
  material: "hudWindow",
  materialOpacity: 0.16,
  tintOpacity: 0.1,
  fill: "transparent",
  stroke: "rgba(48, 176, 199, 0.85)",
  lineWidth: 1.25,
  shadow: {
    color: "rgba(0, 0, 0, 0.22)",
    radius: 5
  }
}

const translations = new TranslationCache({ perform: translate, delay: requestDelay })

// Hovery versions without extension settings pass no settings; the page then asks for setup.
export async function present({ input, selections, root, signal, overlay, extension, settings = {} }) {
  const selection = selections?.[settings.granularity] ?? input
  const text = selection.text.trim()
  overlay.show(selection, highlightStyle)
  const messages = createMessages(extension)
  const view = createView(root, text, settings.model?.trim() || extension?.name, messages)

  const missing = missingSettings(settings, messages)
  if (missing.length > 0) {
    view.showSetup(missing)
    return
  }

  try {
    const translation = await translations.translate(
      {
        baseURL: settings.baseURL,
        apiKey: settings.apiKey,
        model: settings.model,
        targetLanguage: settings.targetLanguage,
        alternateLanguage: settings.alternateLanguage,
        instructions: settings.instructions,
        stream: settings.stream,
        timeout: settings.timeout,
        level: selection.level,
        text
      },
      { signal, onText: text => view.showProgress(text) }
    )
    view.showTranslation(translation)
  } catch (error) {
    if (signal.aborted) throw signal.reason
    view.showError(error)
  }
}

export function unmount({ root }) {
  translations.cancel()
  root.replaceChildren()
}

function missingSettings(settings, messages) {
  const missing = []
  if (!settings.baseURL?.trim()) missing.push(messages.text("setupBaseURL"))
  if (!settings.model?.trim()) missing.push(messages.text("setupModel"))
  return missing
}

function createView(root, text, serviceName, messages) {
  const source = element("section", "card")
  source.append(
    element("p", "text source", text),
    actionBar(copyButton(messages.text("copyOriginal"), () => text, messages))
  )

  const header = element("header", "card-header")
  header.append(serviceIcon(), element("span", "service", serviceName))
  const status = element("p", "note", messages.text("translating"))
  const output = element("p", "text output")
  const actions = actionBar(copyButton(messages.text("copyTranslation"), () => output.textContent, messages))
  actions.hidden = true
  const result = element("section", "card")
  result.append(header, status, output, actions)
  root.replaceChildren(source, result)

  return {
    showProgress(partial) {
      status.hidden = true
      output.classList.add("streaming")
      output.textContent = partial
    },

    showTranslation(translation) {
      status.hidden = true
      output.classList.remove("streaming")
      output.textContent = translation
      actions.hidden = false
    },

    showSetup(missing) {
      result.replaceChildren(
        header,
        element("p", "note", messages.text("setupRequired", { settings: messages.list(missing) }))
      )
    },

    showError(error) {
      const failure = describeFailure(error, messages)
      result.replaceChildren(
        header,
        element("p", "failure", messages.text("translationFailed")),
        element("p", "message", failure.message)
      )
      if (failure.hint) {
        result.append(element("p", "note", failure.hint))
      }
    }
  }
}

function actionBar(...buttons) {
  const bar = element("div", "actions")
  bar.append(...buttons)
  return bar
}

function copyButton(label, text, messages) {
  const button = element("button", "icon-button")
  button.type = "button"
  button.title = label
  button.setAttribute("aria-label", label)
  button.append(copyIcon())
  let reset
  button.addEventListener("click", async () => {
    const copied = await copyText(text())
    clearTimeout(reset)
    button.replaceChildren(copied ? checkmarkIcon() : copyIcon())
    button.title = copied ? messages.text("copied") : messages.text("copyFailed")
    reset = setTimeout(() => {
      button.replaceChildren(copyIcon())
      button.title = label
    }, copiedFeedbackDuration)
  })
  return button
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    return copyWithSelection(text)
  }
}

function copyWithSelection(text) {
  const field = document.createElement("textarea")
  field.value = text
  field.className = "clipboard-buffer"
  document.body.append(field)
  field.select()
  const copied = document.execCommand("copy")
  field.remove()
  return copied
}

function serviceIcon() {
  return icon("service-icon", [
    ["rect", { width: 16, height: 16, rx: 4, class: "service-icon-tile" }],
    ["path", { d: "M4.5 6.25h7M4.5 9.75h4.5", class: "service-icon-lines" }]
  ])
}

function copyIcon() {
  return icon("button-icon", [
    ["rect", { x: 5.25, y: 5.25, width: 8.5, height: 8.5, rx: 2 }],
    ["path", { d: "M10.75 5.25V4.5a2 2 0 0 0-2-2H4.25a2 2 0 0 0-2 2v4.25a2 2 0 0 0 2 2h1" }]
  ])
}

function checkmarkIcon() {
  return icon("button-icon", [["path", { d: "M3.5 8.5l3 3 6-7" }]])
}

function icon(className, shapes) {
  const svg = document.createElementNS(svgNamespace, "svg")
  svg.setAttribute("class", className)
  svg.setAttribute("viewBox", "0 0 16 16")
  svg.setAttribute("aria-hidden", "true")
  for (const [name, attributes] of shapes) {
    const shape = document.createElementNS(svgNamespace, name)
    for (const [attribute, value] of Object.entries(attributes)) {
      shape.setAttribute(attribute, String(value))
    }
    svg.append(shape)
  }
  return svg
}

function element(name, className, text) {
  const node = document.createElement(name)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}
