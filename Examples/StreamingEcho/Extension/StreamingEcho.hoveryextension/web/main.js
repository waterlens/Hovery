import { createComparison, streamSelections } from "./renderer.js"

export function mount({ root, extension }) {
  root.dataset.extensionId = extension.id
}

export async function present({ input, selections, root, signal, overlay }) {
  overlay.show([
    {
      selection: selections.paragraph,
      style: {
        material: "hudWindow",
        materialOpacity: 0.16,
        tintOpacity: 0.1,
        fill: "rgba(175, 82, 222, 0.025)",
        stroke: "rgba(175, 82, 222, 0.82)",
        lineWidth: 1.25,
        lineDash: [7, 4],
        lineCap: "round"
      }
    },
    {
      selection: selections.sentence,
      style: {
        material: "none",
        fill: "rgba(255, 159, 10, 0.025)",
        stroke: "rgba(255, 159, 10, 0.9)",
        lineWidth: 1.5,
        lineDash: [3, 3],
        lineCap: "round"
      }
    },
    {
      selection: selections.word,
      style: {
        material: "none",
        fill: "rgba(10, 132, 255, 0.05)",
        stroke: "rgb(10, 132, 255)",
        lineWidth: 2,
        shadow: {
          color: "rgba(10, 132, 255, 0.32)",
          radius: 4
        }
      }
    }
  ].filter(item => item.selection))
  const results = createComparison(root, selections, input)
  await streamSelections(results, signal)
}

export function unmount({ root }) {
  root.replaceChildren()
}
