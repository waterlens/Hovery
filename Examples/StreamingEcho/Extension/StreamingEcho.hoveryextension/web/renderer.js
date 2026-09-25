const comparisonLevels = ["paragraph", "sentence", "word"]

// `messages` come from i18n.toml in the user's language; each level's message is its label.
export function createComparison(root, selections, input, messages = {}) {
  const comparison = document.createElement("div")
  comparison.className = "comparison"

  const results = comparisonLevels.map(level => {
    const selection = selections?.[level]
      ?? (input?.level === level ? input : null)
    const section = document.createElement("section")
    section.className = `selection selection-${level}`

    const heading = document.createElement("h2")
    heading.textContent = messages[level] ?? level

    const result = document.createElement("p")
    result.className = "selection-text"
    if (!selection?.text) {
      result.classList.add("selection-unavailable")
      result.textContent = messages.unavailable ?? "unavailable"
    }

    section.append(heading, result)
    comparison.append(section)
    return { element: result, text: selection?.text ?? "" }
  })

  root.replaceChildren(comparison)
  return results
}

export async function streamSelections(results, signal) {
  await Promise.all(results.map(result => {
    if (!result.text) return Promise.resolve()
    return appendWords(result.element, result.text, signal)
  }))
}

async function appendWords(element, text, signal) {
  const words = text.split(/(\s+)/)
  for (const word of words) {
    await pause(20)
    signal.throwIfAborted()
    element.append(document.createTextNode(word))
  }
}

function pause(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds))
}
