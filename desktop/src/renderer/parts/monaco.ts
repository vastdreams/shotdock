// Monaco (the VS Code editor) with syntax colouring for common languages. One web worker, bundled by Vite.

import * as monaco from "monaco-editor/editor/editor.api";
import "monaco-editor/basic-languages/monaco.contribution";
import "monaco-editor/editor/contrib/find/browser/findController";
import EditorWorker from "monaco-editor/editor/editor.worker?worker";

(self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = { getWorker: () => new EditorWorker() };

const dark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;
monaco.editor.setTheme(dark() ? "vs-dark" : "vs");
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => monaco.editor.setTheme(dark() ? "vs-dark" : "vs"));

/** A model for a file, coloured by its extension. Re-uses the model if the path is already open. */
export function modelFor(path: string, text: string, kind: "original" | "current"): monaco.editor.ITextModel {
  const uri = monaco.Uri.file(`/${kind}/${path}`);
  const existing = monaco.editor.getModel(uri);
  if (existing) { if (existing.getValue() !== text) existing.setValue(text); return existing; }
  const ext = path.includes(".") ? "." + path.split(".").pop()!.toLowerCase() : "";
  const lang = monaco.languages.getLanguages().find((l: { id: string; extensions?: string[] }) => l.extensions?.includes(ext))?.id;
  return monaco.editor.createModel(text, lang, uri);
}

export { monaco };
