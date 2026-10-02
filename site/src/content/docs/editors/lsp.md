---
title: The language server
description: voltc lsp, what it does, and setting it up in any editor.
sidebar:
  order: 2
---

`voltc lsp` is a language server: it speaks the Language Server Protocol (JSON-RPC over stdin and
stdout) to any editor that has an LSP client. It's built on the compiler itself, so what it reports
is exactly what `voltc check` would.

## What it does

| | |
| --- | --- |
| Diagnostics | errors and warnings, updated as the text changes |
| Hover | a local's or field's type, a function's declaration; on a type, its fields or variants and every fn attached to it, grouped by the trait it's attached for (with the trait's generic arguments); on a trait, its fns and the types that attach it |
| Go to definition | functions, methods, fields (in a struct literal too), locals, parameters, globals, types, into std and dependencies too |
| References | every use of a function, field, local or global |
| Document symbols | the outline: functions, structs with their fields, enums with their variants, traits, namespaces |
| Completion | after `x.`, `x`'s fields and methods; after `a::`, what `a` declares; otherwise locals, the program's names and keywords |
| Signature help | the declaration of the function being called, and which argument you're on |
| Semantic tokens | what every name is, so a theme colors it by meaning: namespaces, structs, enums, traits, generic parameters, functions, methods, parameters, variables (a `val` is read-only), fields, enum variants, `@builtins`; std's names are marked as the default library |
| Inlay hints | the type of a `val`/`var`, a `for`/`match` binding or a closure parameter that doesn't write one; the parameter each call argument is for (not for one-letter parameters, nor where the argument already says it); what a block of 25 lines or more closes (`fn main`), after its `}` |
| Code lenses | references above a function; above a type, how many fns are attached to it and for which traits; above a trait, the types that attach it; Run above `main` |
| Highlights | the name under the cursor, where it's declared and used |
| Rename | a function, type, field, local, parameter or global, in every file of the program (not std's names) |
| Quick fixes | `declare it with var` (a `val` lent to a function that changes it, or assigned), `did you mean +=` for a statement whose value is never used, dropping a `var` a parameter doesn't need, and did-you-mean names and fields |
| Folding | blocks, runs of comments and of `use` lines |

## What it checks

Inlay hints, semantic tokens, code lenses, highlights, rename and quick fixes come from the last
check, so while the text doesn't parse they wait for it to: the editor keeps what it showed, adjusted
to the edits, and rename asks for the errors to be fixed first.

Every change re-checks the whole program: std, plus the document. When the file is under a bolt
package's `src/`, the other `.volt` files there are part of the program too. The package's
libraries, its own and its dependencies', come from `bolt metadata` (so `bolt` has to be on the
editor's `PATH`), read again when `bolt.toml` changes. It runs offline, so a git dependency counts
once `bolt fetch` or a build has downloaded it. A file inside a library is checked as part of that
package. Changes that arrive while the editor is still typing are batched, so a large program is
checked once per pause, not once per key. A file without `main` (a library file, or one being
written) is checked all the same.

The server runs in one process. If it ever crashes, VS Code starts it again (up to four times in
three minutes); other editors have their own setting for that.

## Other editors

Point the editor's LSP client at `voltc lsp` for files ending in `.volt`.

**Neovim** (0.11+):

```lua
vim.filetype.add({ extension = { volt = "volt" } })
vim.lsp.config("volt", { cmd = { "voltc", "lsp" }, filetypes = { "volt" }, root_markers = { "bolt.toml", ".git" } })
vim.lsp.enable("volt")
```

**Helix** (`languages.toml`):

```toml
[language-server.voltc]
command = "voltc"
args = ["lsp"]

[[language]]
name = "volt"
scope = "source.volt"
file-types = ["volt"]
roots = ["bolt.toml"]
comment-token = "//"
language-servers = ["voltc"]
```

**Emacs** (eglot):

```elisp
(define-derived-mode volt-mode prog-mode "Volt")
(add-to-list 'auto-mode-alist '("\\.volt\\'" . volt-mode))
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(volt-mode "voltc" "lsp")))
```

The TextMate grammar in `editors/vscode/syntaxes/volt.tmLanguage.json` works in editors that read
TextMate grammars (Sublime Text, and this site's code blocks).
