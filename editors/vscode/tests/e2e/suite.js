// Runs inside VS Code's extension host (see run.js): the language server has to find voltc by
// itself, then report the error in bad.volt, complete std:: and hover over a function.
const assert = require("node:assert");
const path = require("node:path");
const vscode = require("vscode");

async function until(what, f, ms = 60000) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await f();
    if (v) {
      return v;
    }
    if (Date.now() > end) {
      throw new Error(`timed out waiting for ${what}`);
    }
    await new Promise((r) => setTimeout(r, 250));
  }
}

function at(doc, text, offset) {
  const i = doc.getText().indexOf(text);
  assert.ok(i >= 0, `no ${text} in ${doc.uri.fsPath}`);
  return doc.positionAt(i + offset);
}

exports.run = async function () {
  const root = vscode.workspace.workspaceFolders[0].uri.fsPath;
  const bad = vscode.Uri.file(path.join(root, "bad.volt"));
  await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(bad));
  const diags = await until("an error in bad.volt", () => {
    const d = vscode.languages.getDiagnostics(bad).filter((x) => x.severity === vscode.DiagnosticSeverity.Error);
    return d.length > 0 ? d : undefined;
  });
  assert.strictEqual(diags[0].range.start.line, 1, JSON.stringify(diags));
  console.log(`error: ${diags[0].message}`);

  const good = vscode.Uri.file(path.join(root, "good.volt"));
  const doc = await vscode.workspace.openTextDocument(good);
  await vscode.window.showTextDocument(doc);
  const label = (i) => (typeof i.label === "string" ? i.label : i.label.label);
  const list = await until("completions after std::", async () => {
    const l = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", good, at(doc, "std::println", 5));
    return l && l.items.some((i) => label(i) === "println") ? l : undefined;
  });
  console.log(`completion: ${list.items.length} items, println among them`);
  const hovers = await until("a hover on add", async () => {
    const h = await vscode.commands.executeCommand("vscode.executeHoverProvider", good, at(doc, "add(1, 2)", 1));
    return h && h.length > 0 ? h : undefined;
  });
  const text = hovers.flatMap((h) => h.contents.map((c) => (typeof c === "string" ? c : c.value))).join("\n");
  assert.ok(text.includes("fn add(a: i32, b: i32) -> i32"), text);
  console.log("hover: fn add(a: i32, b: i32) -> i32");
};
