// The Volt site: a custom landing page (src/pages/index.astro) and the docs (Starlight, from
// src/content/docs). Code blocks are highlighted with the VS Code extension's Volt grammar, in the
// board's colours (src/code-themes.mjs).
import { readFileSync } from "node:fs";
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightLinksValidator from "starlight-links-validator";
import { volt, boardDark, boardLight } from "./src/code-themes.mjs";

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
      favicon: "/favicon.svg",
      social: [{ icon: "github", label: "GitHub", href: "https://github.com/ChaseSunstrom/volt-bootstrap" }],
      editLink: { baseUrl: "https://github.com/ChaseSunstrom/volt-bootstrap/edit/main/site/" },
      customCss: ["./src/styles/theme.css", "./src/styles/docs.css"],
      // one header for the landing page and the docs (the landing page is a Starlight page too)
      components: { Header: "./src/components/Header.astro" },
      head: [
        { tag: "link", attrs: { rel: "preconnect", href: "https://fonts.googleapis.com" } },
        { tag: "link", attrs: { rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: true } },
        {
          tag: "link",
          attrs: {
            rel: "stylesheet",
            href: "https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@62..125,100..900&family=Martian+Mono:wdth,wght@75..112.5,100..800&display=swap",
          },
        },
      ],
      // the std pages aren't content pages, so the validator can't see them
      plugins: [starlightLinksValidator({ exclude: stdPages.map((p) => `/volt-bootstrap${p.link}`) })],
      expressiveCode: {
        themes: [boardDark, boardLight],
        shiki: { langs: [volt] },
        styleOverrides: { borderRadius: "0.4rem", codeFontFamily: "var(--v-mono)", uiFontFamily: "var(--v-sans)" },
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
