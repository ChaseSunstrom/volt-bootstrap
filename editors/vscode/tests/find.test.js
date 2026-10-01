// The voltc/bolt finder (src/find.ts): where it looks, in order. Run with `npm test` (after `npm run build`).
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const { find } = require("../out/find.js");

function tree() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "volt-find-"));
  const exe = (...parts) => {
    const p = path.join(root, ...parts);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, "#!/bin/sh\n");
    fs.chmodSync(p, 0o755);
    return p;
  };
  return { root, exe };
}

const none = (home) => ({ setting: "voltc", folders: [], env: { PATH: "" }, home, shellPath: () => undefined });

test("a path in the setting wins, and a wrong one finds nothing", () => {
  const { root, exe } = tree();
  const mine = exe("custom", "voltc");
  exe("bin", "voltc");
  const w = { ...none(root), setting: mine, env: { PATH: path.join(root, "bin") } };
  assert.deepStrictEqual(find("voltc", w), { path: mine, how: "the setting" });
  assert.strictEqual(find("voltc", { ...w, setting: path.join(root, "nope") }), undefined);
});

test("PATH, then the login shell's PATH", () => {
  const { root, exe } = tree();
  const onPath = exe("bin", "voltc");
  const inShell = exe("shellbin", "voltc");
  assert.deepStrictEqual(find("voltc", { ...none(root), env: { PATH: path.join(root, "bin") } }), { path: onPath, how: "PATH" });
  assert.deepStrictEqual(find("voltc", { ...none(root), shellPath: () => path.join(root, "shellbin") }), { path: inShell, how: "your shell's PATH" });
});

test("~/.local/bin, then a Volt checkout in a folder or ~/volt", () => {
  const { root, exe } = tree();
  const local = exe(".local", "bin", "voltc");
  assert.strictEqual(find("voltc", none(root)).path, local);
  fs.rmSync(local);
  const checkout = path.join(root, "work", "volt");
  const voltc = exe("work", "volt", "voltc", "target", "release", "voltc");
  const bolt = exe("work", "volt", "target", "release", "bolt");
  assert.deepStrictEqual(find("voltc", { ...none(root), folders: [checkout] }), { path: voltc, how: "a Volt checkout" });
  assert.strictEqual(find("bolt", { ...none(root), setting: "bolt", folders: [checkout] }).path, bolt);
  const home = exe("volt", "voltc", "target", "debug", "voltc");
  assert.strictEqual(find("voltc", none(root)).path, home);
});

test("nothing anywhere", () => {
  const { root } = tree();
  assert.strictEqual(find("voltc", none(root)), undefined);
});
