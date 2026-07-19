const comparisonLevels = [
  { key: "paragraph", label: "Paragraph" },
  { key: "sentence", label: "Sentence" },
  { key: "word", label: "Word" }
]

export function createComparison(root, selections, input) {
  const comparison = document.createElement("div")
  comparison.className = "comparison"

  const results = comparisonLevels.map(level => {
    const selection = selections?.[level.key]
      ?? (input?.level === level.key ? input : null)
    const section = document.createElement("section")
    section.className = `selection selection-${level.key}`

    const heading = document.createElement("h2")
    heading.textContent = level.label

    const result = document.createElement("p")
    result.className = "selection-text"
    if (!selection?.text) {
      result.classList.add("selection-unavailable")
      result.textContent = "Not available"
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
