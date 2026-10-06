---
title: VS Code
description: The Volt extension for Visual Studio Code.
sidebar:
  order: 1
---

The extension in `editors/vscode` gives VS Code:

- highlighting for `.volt` files, and the file icon, refined by the server's semantic tokens: types,
  generic parameters, traits, namespaces, methods, fields, enum variants and `val`s each by meaning;
- diagnostics as you type, hover, go to definition, find references, the outline, completion and
  signature help, from `voltc lsp`;
- inlay hints (the types of locals and closure parameters that don't write one, parameter names at
  calls, what a long block closes), code lenses
  (references, the fns and traits attached to a type, **Run** above `main`), highlights, rename,
  folding and quick fixes (see [the language server](/volt-bootstrap/editors/lsp/));
- **Volt: Expand Comptime** (command palette): what the comptime code on the cursor's line (or in
  the file) became, beside it: values, `comptime if` branches, generic instances, built types,
  the fns comptime fns declared and `@derive` output;
- snippets (`main`, `fn`, `attach`, `struct`, `enum`, `error`, `match`, `for`, `usec`...);
- bolt tasks (check, build, build --release, run, test, clean) in folders with a `bolt.toml`, and
  the `$volt` problem matcher, which links voltc's errors to the code.

## Install

From a checkout, one command builds the extension and installs it into VS Code:

```sh
cd editors/vscode
npm install && npm run install-extension
```

The extension finds `voltc` the way a terminal would, so it works when VS Code was started from a
desktop menu (which doesn't read `~/.bashrc`): `volt.serverPath` when it's a path, then VS Code's
`PATH`, then your login shell's `PATH`, then `~/.local/bin`, then a Volt checkout in a workspace
folder or `~/volt` (`voltc/target/release/voltc`, then `debug`). bolt, for tasks, is found the same
way. The status bar shows **Volt** while the server runs, with the voltc it found in its tooltip;
click it to restart the server. If no voltc is found, a notice says so, with **Set path** and
**Install guide**.

The server finds std the way voltc does (`$VOLT_STD`, or a `std/` next to voltc); `volt.stdPath`
overrides that.

## Settings

| Setting | Default | |
| --- | --- | --- |
| `volt.serverPath` | `voltc` | the voltc that runs the language server |
| `volt.stdPath` | (empty) | the std package to check against |
| `volt.boltPath` | `bolt` | the bolt that runs tasks |
| `volt.inlayHints.types` | `true` | the type of a local that doesn't write one |
| `volt.inlayHints.parameters` | `true` | which parameter each call argument is for |
| `volt.inlayHints.closingBraces` | `true` | what a block of 25 lines or more closes, after its `}` |

VS Code's own `editor.inlayHints.enabled` turns every inlay hint on or off.

**Volt: Restart Language Server** restarts the server, after rebuilding voltc for example.
**Volt: Run This Program** runs the open file (`bolt run` in a bolt package, else `voltc run`), as
the **Run** lens above `main` does.

## Tasks

**Terminal → Run Task → bolt** lists the tasks. Define your own in `.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "type": "bolt",
      "command": "build",
      "args": ["--profile", "small"],
      "problemMatcher": ["$volt"],
      "group": "build"
    }
  ]
}
```

## Developing the extension

`npm test`, run in `editors/vscode`, runs the grammar's tests (the assertion files in
`editors/vscode/tests/grammar` and a snapshot of `editors/vscode/tests/snap/sample.volt`) and the
voltc finder's tests. After a
deliberate grammar change, `npx vscode-tmgrammar-snap -u 'tests/snap/*.volt'` updates the snapshot.

`VOLTC=/path/to/voltc npm run test:e2e` runs the extension in a real VS Code (downloaded into
`.vscode-test/` the first time; under `xvfb-run` without a display). voltc is only in a checkout
inside the test's workspace, not on `PATH` (the editor gets a `HOME` of its own, so no shell profile
adds one), and the test waits for an error in a broken file, completion after `std::`, a hover,
semantic tokens, an inlay hint and the code lenses.
