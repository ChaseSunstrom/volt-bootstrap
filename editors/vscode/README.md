# Volt for Visual Studio Code

Language support for [Volt](https://github.com/ChaseSunstrom/volt-bootstrap):

- **Highlighting** for `.volt` files (the TextMate grammar in `syntaxes/`, which the website uses too)
- **Diagnostics** as you type, from the compiler itself (`voltc lsp`)
- **Hover** shows a name's type or a function's declaration
- **Go to definition** and **find references**
- **Outline** of a file's declarations
- **Completion**: fields and methods after `x.`, a namespace's names after `std::`, locals and keywords
- **Signature help** inside a call's parentheses
- **Snippets** for common declarations (`main`, `fn`, `struct`, `match`, ...)
- **bolt tasks** (check, build, run, test, clean) in folders with a `bolt.toml`, with voltc's errors
  linked to their places (the `$volt` problem matcher)

## Requirements

`voltc` (the self-hosted compiler) on your PATH, or set `volt.serverPath`. The server finds std the
way the compiler does (`$VOLT_STD`, or a `std/` next to voltc); `volt.stdPath` overrides that.

In a bolt package, a file under `src/` is checked together with the other files there.

## Settings

| Setting | Default | |
| --- | --- | --- |
| `volt.serverPath` | `voltc` | the voltc that runs `voltc lsp` |
| `volt.stdPath` | (empty) | the std package to check against |
| `volt.boltPath` | `bolt` | the bolt that runs tasks |

**Volt: Restart Language Server** restarts it (after rebuilding voltc, say).

## Other editors

The server speaks the Language Server Protocol over stdin and stdout: point any LSP client at
`voltc lsp`.

## Developing

```sh
npm install
npm test                  # grammar tests (tests/grammar) and the snapshot (tests/snap)
npx @vscode/vsce package  # volt-lang-VERSION.vsix
```

`npx vscode-tmgrammar-snap -u 'tests/snap/*.volt'` rewrites the snapshot after a deliberate grammar
change.
