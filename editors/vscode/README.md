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

## Install

```sh
npm install && npm run install-extension   # in editors/vscode: packages the .vsix and installs it
```

The extension finds `voltc` the way a terminal would, so it works when VS Code was started from a
desktop menu (which doesn't read `~/.bashrc`): `volt.serverPath` when it's a path, then VS Code's
`PATH`, then your login shell's `PATH`, then `~/.local/bin`, then a Volt checkout in a workspace
folder or `~/volt` (`voltc/target/release/voltc`, then `debug`). bolt, for tasks, is found the same
way. The status bar shows **Volt** while the server runs, with the voltc it found in its tooltip;
click it to restart the server. If no voltc is found, a notice says so, with **Set path** and
**Install guide**.

The server finds std the way the compiler does (`$VOLT_STD`, or a `std/` next to voltc);
`volt.stdPath` overrides that.

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
`voltc lsp` (it accepts the `--stdio` flag clients add).

## Developing

```sh
npm install
npm test                                  # grammar tests, the snapshot, the voltc finder's tests
VOLTC=/path/to/voltc npm run test:e2e     # in a real VS Code (xvfb-run without a display)
npx @vscode/vsce package                  # volt-lang-VERSION.vsix
```

`npx vscode-tmgrammar-snap -u 'tests/snap/*.volt'` rewrites the snapshot after a deliberate grammar
change.
