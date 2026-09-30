// The Volt extension: starts the language server (`voltc lsp`) for .volt files, and offers bolt's
// commands as tasks (with a problem matcher for voltc's errors) in folders that hold a bolt.toml.
import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, ServerOptions, TransportKind } from "vscode-languageclient/node";

let client: LanguageClient | undefined;

function settings(): vscode.WorkspaceConfiguration {
  return vscode.workspace.getConfiguration("volt");
}

async function startServer(): Promise<void> {
  const command = settings().get<string>("serverPath") || "voltc";
  const std = settings().get<string>("stdPath");
  const server: ServerOptions = { command, args: std ? ["lsp", "--std", std] : ["lsp"], transport: TransportKind.stdio };
  const options: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "volt" }],
    outputChannelName: "Volt Language Server",
  };
  client = new LanguageClient("volt", "Volt", server, options);
  try {
    await client.start();
  } catch (e) {
    client = undefined;
    vscode.window.showErrorMessage(`Volt: couldn't start \`${command} lsp\` (${e}). Set volt.serverPath to your voltc.`);
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
    const bolt = settings().get<string>("boltPath") || "bolt";
    const name = [def.command, ...def.args].join(" ");
    const exec = new vscode.ProcessExecution(bolt, [def.command, ...def.args], { cwd: folder.uri.fsPath });
    return new vscode.Task(def, folder, name, "bolt", exec, ["$volt"]);
  }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  context.subscriptions.push(
    vscode.tasks.registerTaskProvider("bolt", new BoltTasks()),
    vscode.commands.registerCommand("volt.restartServer", async () => {
      await stopServer();
      await startServer();
    }),
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (e.affectsConfiguration("volt.serverPath") || e.affectsConfiguration("volt.stdPath")) {
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
