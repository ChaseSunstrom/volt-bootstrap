// The Volt extension: starts the language server (`voltc lsp`) for .volt files, and offers bolt's
// commands as tasks (with a problem matcher for voltc's errors) in folders that hold a bolt.toml.
// voltc and bolt are found where a terminal would find them (see find.ts), and the status bar
// says whether the server is running.
import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, ServerOptions } from "vscode-languageclient/node";
import { find, where } from "./find";

const GUIDE = "https://chasesunstrom.github.io/volt-bootstrap/editors/vscode/";
let client: LanguageClient | undefined;
let status: vscode.StatusBarItem;

function settings(): vscode.WorkspaceConfiguration {
  return vscode.workspace.getConfiguration("volt");
}

function folders(): string[] {
  return (vscode.workspace.workspaceFolders ?? []).map((f) => f.uri.fsPath);
}

/** voltc or bolt: the setting's path, or where a terminal would find it */
function locate(name: "voltc" | "bolt"): { path: string; how: string } | undefined {
  const setting = settings().get<string>(name === "voltc" ? "serverPath" : "boltPath") || name;
  return find(name, where(setting, folders()));
}

function show(state: "running" | "missing" | "failed", detail: string): void {
  status.text = state === "running" ? "$(zap) Volt" : "$(warning) Volt";
  status.tooltip = `${detail}\nClick to restart the language server.`;
  status.show();
}

async function notFound(what: string): Promise<void> {
  const pick = await vscode.window.showErrorMessage(what, "Set path", "Install guide");
  if (pick === "Set path") {
    await vscode.commands.executeCommand("workbench.action.openSettings", "volt.serverPath");
  } else if (pick === "Install guide") {
    await vscode.env.openExternal(vscode.Uri.parse(GUIDE));
  }
}

async function startServer(): Promise<void> {
  const voltc = locate("voltc");
  if (!voltc) {
    const setting = settings().get<string>("serverPath");
    const what = setting && setting !== "voltc" ? `volt.serverPath is ${setting}, which isn't a voltc that can run.` : "can't find voltc: not on PATH, in your shell's PATH, ~/.local/bin or a Volt checkout.";
    show("missing", `Volt: ${what}`);
    await notFound(`Volt: ${what} Errors, completion and hover need it.`);
    return;
  }
  const std = settings().get<string>("stdPath");
  // stdin and stdout (no transport given: one would add --stdio to the arguments)
  const server: ServerOptions = { command: voltc.path, args: std ? ["lsp", "--std", std] : ["lsp"] };
  const options: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "volt" }],
    outputChannelName: "Volt Language Server",
  };
  client = new LanguageClient("volt", "Volt", server, options);
  try {
    await client.start();
    show("running", `Volt language server: ${voltc.path} (found through ${voltc.how})`);
  } catch (e) {
    client = undefined;
    show("failed", `Volt: \`${voltc.path} lsp\` didn't start: ${e}`);
    await notFound(`Volt: \`${voltc.path} lsp\` didn't start (${e}). It may need std: set volt.stdPath or $VOLT_STD.`);
  }
}

async function stopServer(): Promise<void> {
  const c = client;
  client = undefined;
  await c?.stop();
}

// bolt's everyday commands, for each workspace folder that is a bolt package or workspace
class BoltTasks implements vscode.TaskProvider {
  static readonly COMMANDS: [string, string[], vscode.TaskGroup | undefined][] = [
    ["check", [], undefined],
    ["build", [], vscode.TaskGroup.Build],
    ["build", ["--release"], vscode.TaskGroup.Build],
    ["run", [], undefined],
    ["test", [], vscode.TaskGroup.Test],
    ["clean", [], vscode.TaskGroup.Clean],
  ];

  provideTasks(): vscode.Task[] {
    const tasks: vscode.Task[] = [];
    for (const folder of vscode.workspace.workspaceFolders ?? []) {
      if (!fs.existsSync(path.join(folder.uri.fsPath, "bolt.toml"))) {
        continue;
      }
      for (const [command, args, group] of BoltTasks.COMMANDS) {
        const task = this.task(folder, { type: "bolt", command, args });
        task.group = group;
        tasks.push(task);
      }
    }
    return tasks;
  }

  resolveTask(task: vscode.Task): vscode.Task | undefined {
    const def = task.definition as vscode.TaskDefinition & { command?: string; args?: string[] };
    if (!def.command || typeof task.scope !== "object") {
      return undefined;
    }
    return this.task(task.scope, { type: "bolt", command: def.command, args: def.args ?? [] });
  }

  private task(folder: vscode.WorkspaceFolder, def: { type: string; command: string; args: string[] }): vscode.Task {
    const bolt = locate("bolt")?.path ?? (settings().get<string>("boltPath") || "bolt");
    const name = [def.command, ...def.args].join(" ");
    const exec = new vscode.ProcessExecution(bolt, [def.command, ...def.args], { cwd: folder.uri.fsPath });
    return new vscode.Task(def, folder, name, "bolt", exec, ["$volt"]);
  }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  status.command = "volt.restartServer";
  context.subscriptions.push(
    status,
    vscode.tasks.registerTaskProvider("bolt", new BoltTasks()),
    vscode.commands.registerCommand("volt.restartServer", async () => {
      await stopServer();
      await startServer();
    }),
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (e.affectsConfiguration("volt.serverPath") || e.affectsConfiguration("volt.stdPath") || e.affectsConfiguration("volt.boltPath")) {
        await stopServer();
        await startServer();
      }
    }),
  );
  await startServer();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
