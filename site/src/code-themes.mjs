// The site's code colours, for the docs (Expressive Code, in astro.config.mjs) and the landing page
// alike: Volt's grammar from the VS Code extension, and two themes in the site's colours, dark (night
// violet) and light (lavender paper). Paths are from site/, where the site is built.
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

export const codeDark = theme("volt-night", "dark", {
  bg: "#110d29",
  fg: "#e6e1ff",
  comment: "#7d76a8",
  keyword: "#c4b5ff",
  string: "#f5b38a",
  number: "#7fd8c9",
  fn: "#ffffff",
  type: "#9fb8ff",
});

export const codeLight = theme("volt-paper", "light", {
  bg: "#f1edff",
  fg: "#1b1538",
  comment: "#6f6898",
  keyword: "#5a2ee0",
  string: "#a64b16",
  number: "#0f7a6c",
  fn: "#120d2c",
  type: "#2e4fc4",
});
