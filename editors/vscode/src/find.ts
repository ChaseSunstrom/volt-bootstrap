// Finding voltc and bolt without relying on VS Code's PATH: an editor started from a desktop menu
// doesn't read ~/.bashrc, so the PATH line the install guide adds there isn't in it. No vscode
// import here, so tests can run this with plain node.
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

export interface Where {
  /** the setting's value: a path, or a bare name (the default) */
  setting: string;
  /** the workspace folders' paths */
  folders: string[];
  env: NodeJS.ProcessEnv;
  home: string;
  /** the login shell's PATH (asked once, lazily); undefined when it can't be asked */
  shellPath?: () => string | undefined;
}

function isExe(p: string): boolean {
  try {
    return fs.statSync(p).isFile() && (process.platform === "win32" || (fs.statSync(p).mode & 0o111) !== 0);
  } catch {
    return false;
  }
}

function onPath(name: string, pathVar: string | undefined): string | undefined {
  const exts = process.platform === "win32" ? ["", ".exe", ".cmd"] : [""];
  for (const dir of (pathVar ?? "").split(path.delimiter).filter((d) => d.length > 0)) {
    for (const ext of exts) {
      const p = path.join(dir, name + ext);
      if (isExe(p)) {
        return p;
      }
    }
  }
  return undefined;
}

/** the PATH an interactive login shell sets up (what a terminal sees) */
export function loginShellPath(env: NodeJS.ProcessEnv): string | undefined {
  if (process.platform === "win32") {
    return undefined;
  }
  try {
    const shell = env.SHELL || "/bin/sh";
    const out = execFileSync(shell, ["-ilc", "echo __VOLT_PATH__$PATH"], { env, timeout: 4000, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    const line = out.split("\n").find((l) => l.startsWith("__VOLT_PATH__"));
    return line?.slice("__VOLT_PATH__".length).trim();
  } catch {
    return undefined;
  }
}

/**
 * where `name` (voltc or bolt) is, and how it was found: the setting when it's a path; else PATH,
 * the login shell's PATH, ~/.local/bin, and a Volt checkout in a workspace folder or ~/volt (voltc
 * in voltc/target/{release,debug}, bolt in target/{release,debug})
 */
export function find(name: string, w: Where): { path: string; how: string } | undefined {
  const setting = w.setting.trim().replace(/^~(?=$|\/)/, w.home);
  if (setting.length > 0 && setting !== name) {
    return isExe(setting) ? { path: setting, how: "the setting" } : undefined;
  }
  const direct = onPath(name, w.env.PATH);
  if (direct) {
    return { path: direct, how: "PATH" };
  }
  const shell = w.shellPath?.();
  const viaShell = onPath(name, shell);
  if (viaShell) {
    return { path: viaShell, how: "your shell's PATH" };
  }
  const roots = [...w.folders, path.join(w.home, "volt")];
  const sub = name === "voltc" ? ["voltc", "target"] : ["target"];
  const candidates = [path.join(w.home, ".local", "bin", name)];
  for (const root of roots) {
    for (const profile of ["release", "debug"]) {
      candidates.push(path.join(root, ...sub, profile, name));
      // a workspace opened at voltc/ itself
      if (name === "voltc") {
        candidates.push(path.join(root, "target", profile, name));
      }
    }
  }
  const hit = candidates.find(isExe);
  return hit ? { path: hit, how: "a Volt checkout" } : undefined;
}

/** find with the real environment */
export function where(setting: string, folders: string[]): Where {
  let asked = false;
  let cached: string | undefined;
  return {
    setting,
    folders,
    env: process.env,
    home: os.homedir(),
    shellPath: () => {
      if (!asked) {
        asked = true;
        cached = loginShellPath(process.env);
      }
      return cached;
    },
  };
}
