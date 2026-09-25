// Checks Hovery's string catalog against the strings that the Swift compiler extracts while it builds
// the app (SWIFT_EMIT_LOC_STRINGS): every string needs a Simplified Chinese translation, and the catalog
// must not keep strings the sources no longer use. Xcode updates catalogs from the same extraction, so
// keys and placeholder types match exactly. Tracked files are never modified.
//
// Usage: node Scripts/check-localizations.mjs [derived data directory] [configuration]

import { existsSync, readFileSync, readdirSync } from "node:fs"
import { dirname, join, relative } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const catalogPath = join(root, "Hovery", "Resources", "Localizable.xcstrings")
const table = "Localizable"
const language = "zh-Hans"

const [derivedData = join(root, ".build", "Hovery"), configuration = "Debug"] = process.argv.slice(2)
const objectsDirectory = join(
  derivedData, "Build", "Intermediates.noindex", "Hovery.build", configuration, "Hovery.build", "Objects-normal"
)

// A printf-style placeholder; the capture is its type, without position, flags, width, or precision.
const placeholders = /%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?((?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOeEfFgGaAcCsSp]|%)/g

function placeholderTypes(text) {
  return [...text.matchAll(placeholders)]
    .map(match => match[1])
    .filter(type => type !== "%")
    .sort()
    .join()
}

function stringUnits(value) {
  if (!value || typeof value !== "object") return []
  return Object.entries(value).flatMap(([name, child]) => name === "stringUnit" ? [child] : stringUnits(child))
}

/** The strings in the sources, each with the places that use it. */
function extractedStrings() {
  if (!existsSync(objectsDirectory)) {
    throw new Error(`${relative(root, objectsDirectory)} does not exist; build Hovery first.`)
  }
  const strings = new Map()
  for (const architecture of readdirSync(objectsDirectory)) {
    const directory = join(objectsDirectory, architecture)
    for (const name of readdirSync(directory).filter(name => name.endsWith(".stringsdata"))) {
      const data = JSON.parse(readFileSync(join(directory, name), "utf8"))
      // Incremental builds keep the extracted strings of deleted sources.
      if (!existsSync(data.source)) continue
      for (const string of data.tables?.[table] ?? []) {
        const location = `${relative(root, data.source)}:${string.location?.startingLine ?? "?"}`
        strings.set(string.key, (strings.get(string.key) ?? new Set()).add(location))
      }
    }
  }
  return strings
}

const catalog = JSON.parse(readFileSync(catalogPath, "utf8"))
const extracted = extractedStrings()
const problems = []

for (const [key, locations] of extracted) {
  if (!(key in catalog.strings)) {
    problems.push(`Missing: ${JSON.stringify(key)} (${[...locations].join(", ")}) needs a catalog entry.`)
  }
}
for (const [key, entry] of Object.entries(catalog.strings)) {
  const name = JSON.stringify(key)
  if (!extracted.has(key)) {
    problems.push(`Unused: ${name} is no longer used by the sources; remove it from the catalog.`)
    continue
  }
  if (entry.shouldTranslate === false) continue

  const units = stringUnits(entry.localizations?.[language])
  if (units.length === 0 || units.some(unit => unit.state !== "translated" || !unit.value)) {
    problems.push(`Untranslated: ${name} (${[...extracted.get(key)].join(", ")}) needs a ${language} translation.`)
    continue
  }
  const source = entry.localizations?.en?.stringUnit?.value ?? key
  for (const unit of units.filter(unit => placeholderTypes(unit.value) !== placeholderTypes(source))) {
    problems.push(`Mismatched placeholders: the ${language} translation of ${name} is ${JSON.stringify(unit.value)}.`)
  }
}

if (problems.length > 0) {
  console.error(`${relative(root, catalogPath)} is out of date:`)
  for (const problem of problems) console.error(`  ${problem}`)
  process.exitCode = 1
} else {
  console.log(
    `${relative(root, catalogPath)} is up to date: all ${extracted.size} strings are used,`
      + ` and each is translated into ${language} or marked as not translatable.`
  )
}
