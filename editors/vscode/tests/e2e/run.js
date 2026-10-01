// End to end, in a real VS Code (downloaded once into .vscode-test/): a workspace where voltc is
// only in a Volt checkout's voltc/target/release (not on PATH, as for an editor started from a
// desktop menu), and the suite checks errors, completion and hover. On Linux without a display,
// run it under xvfb-run. `VOLTC=/path/to/voltc npm run test:e2e`; std comes from $VOLT_STD or
// the repository's.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { runTests } = require("@vscode/test-electron");

async function main() {
  const voltc = process.env.VOLTC;
  if (!voltc || !fs.existsSync(voltc)) {
    throw new Error("set VOLTC to a built voltc");
  }
  const ext = path.resolve(__dirname, "../..");
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "volt-e2e-"));
  const bin = path.join(ws, "voltc", "target", "release");
  fs.mkdirSync(bin, { recursive: true });
  fs.copyFileSync(voltc, path.join(bin, "voltc"));
  fs.chmodSync(path.join(bin, "voltc"), 0o755);
  fs.writeFileSync(path.join(ws, "bad.volt"), 'fn main() -> void {\n    val x: i32 = "text";\n}\n');
  fs.writeFileSync(path.join(ws, "good.volt"), 'use std::io;\n\nfn add(a: i32, b: i32) -> i32 {\n    return a + b;\n}\n\nfn main() -> void {\n    val total = add(1, 2);\n    std::println("{}", total);\n}\n');
  // PATH without voltc's directory, as a desktop launcher would give it
  const PATH = (process.env.PATH ?? "").split(path.delimiter).filter((d) => !fs.existsSync(path.join(d, "voltc"))).join(path.delimiter);
  await runTests({
    extensionDevelopmentPath: ext,
    extensionTestsPath: path.join(__dirname, "suite.js"),
    launchArgs: [ws, "--disable-extensions", "--disable-workspace-trust", "--skip-welcome", "--skip-release-notes"],
    extensionTestsEnv: { PATH, VOLT_STD: process.env.VOLT_STD ?? path.resolve(ext, "../../std"), SHELL: "/bin/false" },
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
