// The site's code colours, for the docs (Expressive Code, in astro.config.mjs) and the landing page
// alike: Volt's grammar from the VS Code extension, and two themes in the board's colours, dark (the
// board) and light (silkscreen paper). Paths are from site/, where the site is built.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const grammar = JSON.parse(readFileSync(resolve(process.cwd(), "../editors/vscode/syntaxes/volt.tmLanguage.json"), "utf8"));
export const volt = { ...grammar, name: "volt" };

function theme(name, type, c) {
  return {
    name,
    type,
    colors: { "editor.background": c.bg, "editor.foreground": c.fg },
    tokenColors: [
      { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: c.comment } },
      { scope: ["keyword", "keyword.control", "keyword.operator.new", "storage", "storage.type", "storage.modifier"], settings: { foreground: c.keyword } },
      { scope: ["string", "string.quoted", "constant.character"], settings: { foreground: c.string } },
      { scope: ["constant.numeric", "constant.language"], settings: { foreground: c.number } },
      { scope: ["entity.name.function", "support.function", "meta.function-call"], settings: { foreground: c.fn } },
      { scope: ["entity.name.type", "support.type", "storage.type.primitive", "entity.name.class"], settings: { foreground: c.type } },
      { scope: ["variable", "variable.other", "meta.definition.variable"], settings: { foreground: c.fg } },
    ],
  };
}

export const boardDark = theme("volt-board", "dark", {
  bg: "#0b2e23",
  fg: "#dbe5de",
  comment: "#7a978a",
  keyword: "#d8b04a",
  string: "#e2a46c",
  number: "#9fd3b9",
  fn: "#f4f7f2",
  type: "#8cc7ad",
});

export const boardLight = theme("volt-paper", "light", {
  bg: "#e9efea",
  fg: "#102a21",
  comment: "#5b7367",
  keyword: "#7d5f0c",
  string: "#934f1c",
  number: "#1d6649",
  fn: "#0b211a",
  type: "#2a654f",
});
