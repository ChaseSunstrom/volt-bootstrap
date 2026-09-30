// The Volt site: a custom landing page (src/pages/index.astro) and the docs (Starlight, from
// src/content/docs). Code blocks are highlighted with the VS Code extension's Volt grammar.
import { readFileSync } from "node:fs";
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightLinksValidator from "starlight-links-validator";

const volt = JSON.parse(readFileSync(new URL("../editors/vscode/syntaxes/volt.tmLanguage.json", import.meta.url), "utf8"));
// the std reference's pages (src/pages/std/[file].astro), one per std source file
const std = JSON.parse(readFileSync(new URL("./src/data/std.json", import.meta.url), "utf8"));
const stdPages = std.files.map((f) => {
  const name = f.file.replace(/\.volt$/, "");
  return { label: `std::${name}`, link: `/std/${name}/` };
});

export default defineConfig({
  site: "https://chasesunstrom.github.io",
  base: "/volt-bootstrap",
  integrations: [
    starlight({
      title: "Volt",
      description: "A systems language with no runtime, a C and an LLVM backend, and a build tool.",
      logo: { src: "./src/assets/volt-mark.svg", alt: "Volt" },
      favicon: "/favicon.svg",
      social: [{ icon: "github", label: "GitHub", href: "https://github.com/ChaseSunstrom/volt-bootstrap" }],
      editLink: { baseUrl: "https://github.com/ChaseSunstrom/volt-bootstrap/edit/main/site/" },
      customCss: ["./src/styles/docs.css"],
      // the std pages aren't content pages, so the validator can't see them
      plugins: [starlightLinksValidator({ exclude: stdPages.map((p) => `/volt-bootstrap${p.link}`) })],
      expressiveCode: {
        shiki: { langs: [{ ...volt, name: "volt" }] },
        styleOverrides: { borderRadius: "0.6rem" },
      },
      sidebar: [
        { label: "Start here", items: [{ autogenerate: { directory: "start" } }] },
        { label: "Language guide", items: [{ autogenerate: { directory: "guide" } }] },
        { label: "Standard library", items: [{ autogenerate: { directory: "std" } }, ...stdPages] },
        { label: "voltc", items: [{ autogenerate: { directory: "voltc" } }] },
        { label: "bolt", items: [{ autogenerate: { directory: "bolt" } }] },
        { label: "Interop", items: [{ autogenerate: { directory: "interop" } }] },
        { label: "Editors", items: [{ autogenerate: { directory: "editors" } }] },
        { label: "Internals", items: [{ autogenerate: { directory: "internals" } }] },
      ],
    }),
  ],
});
