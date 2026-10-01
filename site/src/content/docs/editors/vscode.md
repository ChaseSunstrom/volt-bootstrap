---
title: VS Code
description: The Volt extension for Visual Studio Code.
sidebar:
  order: 1
---

The extension in `editors/vscode` gives VS Code:

- highlighting for `.volt` files, and the file icon;
- diagnostics as you type, hover, go to definition, find references, the outline, completion and
  signature help, from `voltc lsp`;
- snippets (`main`, `fn`, `attach`, `struct`, `enum`, `error`, `match`, `for`, `usec`...);
- bolt tasks (check, build, build --release, run, test, clean) in folders with a `bolt.toml`, and
  the `$volt` problem matcher, which links voltc's errors to the code.

## Install

Build the `.vsix` and install it:

```sh
cd editors/vscode
npm install
npx @vscode/vsce package                      # volt-lang-0.1.0.vsix
code --install-extension volt-lang-0.1.0.vsix
```

The extension runs `voltc lsp`, so `voltc` needs to be on your `PATH` (or set `volt.serverPath`),
and it needs to find std: through `$VOLT_STD`, a `std/` next to voltc, or `volt.stdPath`.

## Settings

| Setting | Default | |
| --- | --- | --- |
| `volt.serverPath` | `voltc` | the voltc that runs the language server |
| `volt.stdPath` | (empty) | the std package to check against |
| `volt.boltPath` | `bolt` | the bolt that runs tasks |

**Volt: Restart Language Server** restarts the server, after rebuilding voltc for example.

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

`npm test`, run in `editors/vscode`, runs the grammar's tests. It checks the assertion files in
`editors/vscode/tests/grammar`, and a snapshot of `editors/vscode/tests/snap/sample.volt`. After a
deliberate change, `npx vscode-tmgrammar-snap -u 'tests/snap/*.volt'` updates the snapshot.
