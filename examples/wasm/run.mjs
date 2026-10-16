// node run.mjs MODULE.wasm wasi|none|imports: runs a module voltc built for --target wasm32-wasi
// (through node's WASI) or wasm32-none (giving it the console and exit a web page would), its exit
// code this script's; imports lists what the module imports, one module.name a line
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const [file, kind] = process.argv.slice(2);
const bytes = await readFile(file);
if (kind === "imports") {
    for (const i of WebAssembly.Module.imports(new WebAssembly.Module(bytes))) {
        console.log(`${i.module}.${i.name}`);
    }
} else if (kind === "wasi") {
    const wasi = new WASI({ version: "preview1", args: [file], env: {}, returnOnExit: true });
    const { instance } = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasi.wasiImport });
    process.exitCode = wasi.start(instance);
} else {
    // what a page gives a wasm32-none module: where its text goes, and how it ends
    class Exit {
        constructor(code) { this.code = code; }
    }
    let memory;
    const text = new TextDecoder();
    const env = {
        volt_console_write: (p, n) => { process.stdout.write(text.decode(new Uint8Array(memory.buffer, p, n))); },
        volt_exit: (code) => { throw new Exit(code); },
    };
    const { instance } = await WebAssembly.instantiate(bytes, { env });
    memory = instance.exports.memory;
    try {
        instance.exports._start();
        process.exitCode = 0;
    } catch (e) {
        if (!(e instanceof Exit)) {
            throw e;
        }
        process.exitCode = e.code;
    }
}
