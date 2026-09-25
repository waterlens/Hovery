const dictionaryCapability = "org.hovery.capability.system-dictionary"

export async function present({ input, root, signal, capabilities, overlay, extension }) {
  const messages = extension?.messages ?? {}
  overlay.showInput({
    material: "hudWindow",
    materialOpacity: 0.16,
    tintOpacity: 0.1,
    fill: "transparent",
    stroke: "rgba(10, 132, 255, 0.82)",
    lineWidth: 1.25,
    shadow: {
      color: "rgba(0, 0, 0, 0.22)",
      radius: 5
    }
  })
  showStatus(root, localized(messages, "lookingUp", { term: input.text }))

  const result = await capabilities.invoke(dictionaryCapability, "lookup", {
    text: input.text
  })
  signal.throwIfAborted()

  if (result.found === false) {
    showPlainDefinition(root, result.term, localized(messages, "noDefinition"), null)
  } else if (result.format === "html") {
    showRichDefinition(root, result.content)
  } else {
    showPlainDefinition(root, result.term, result.content, result.dictionary)
  }
}

export function unmount({ root }) {
  root.replaceChildren()
}

function showRichDefinition(root, source) {
  const parsed = new DOMParser().parseFromString(source, "text/html")
  const fragment = document.createDocumentFragment()

  for (const style of parsed.querySelectorAll("style")) {
    const localStyle = document.createElement("style")
    localStyle.textContent = style.textContent
    fragment.append(localStyle)
  }

  const article = document.createElement("article")
  article.className = "dictionary-entry"
  for (const child of parsed.body.childNodes) {
    article.append(document.importNode(child, true))
  }
  for (const unsafeElement of article.querySelectorAll("script, iframe, object, embed")) {
    unsafeElement.remove()
  }

  fragment.append(article)
  root.replaceChildren(fragment)
}

function showPlainDefinition(root, term, content, dictionary) {
  const article = document.createElement("article")
  article.className = "plain-definition"

  const heading = document.createElement("h1")
  heading.textContent = term
  article.append(heading)

  if (dictionary) {
    const source = document.createElement("p")
    source.className = "dictionary-name"
    source.textContent = dictionary
    article.append(source)
  }

  const definition = document.createElement("p")
  definition.className = "definition"
  definition.textContent = content
  article.append(definition)
  root.replaceChildren(article)
}

function showStatus(root, message) {
  const status = document.createElement("p")
  status.className = "status"
  status.textContent = message
  root.replaceChildren(status)
}

// Messages come from i18n.toml in the user's language. A missing message shows its key.
function localized(messages, key, values = {}) {
  return (messages[key] ?? key).replace(/\{(\w+)\}/g, (placeholder, name) => values[name] ?? placeholder)
}
