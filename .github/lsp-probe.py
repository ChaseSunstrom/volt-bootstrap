# CI probe (T-0673): drive `voltc lsp` through a document whose first version doesn't parse, printing
# every message the server sends and its stderr, so a server that goes quiet shows where it stops.
# usage: python lsp-probe.py VOLTC STD_DIR [test]
# test: the URI as tests/lsp.rs wrote it (file:// + the directory as the OS spells it, backslashes on
# Windows) and a rootUri (file:///C:/...), as that test's session has
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

voltc, std = sys.argv[1], sys.argv[2]
d = tempfile.mkdtemp(prefix="lsp-probe-")
mode = sys.argv[3] if len(sys.argv) > 3 else ""
uri = "file://" + d.replace("\\", "/") + "/c.volt"
root = None
if mode == "test":
    uri = "file://" + d + os.sep + "c.volt"
    root = "file:///" + d.replace("\\", "/").lstrip("/")
text = "fn twice(x: i32) -> i32 {\n    return x * 2;\n}\n\nfn broken() -> void {\n    val y = ;\n}\n\nfn main() -> void {\n    val n = twice(4);\n}\n"
p = subprocess.Popen([voltc, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ, VOLT_STD=std))
t0 = time.time()


def stamp():
    return "%6.1fs" % (time.time() - t0)


def errs():
    for line in p.stderr:
        print(stamp(), "stderr:", line.decode(errors="replace").rstrip(), flush=True)


def outs():
    while True:
        h = {}
        while True:
            line = p.stdout.readline()
            if not line:
                print(stamp(), "server closed its output", flush=True)
                return
            if line in (b"\r\n", b"\n"):
                break
            k, v = line.decode().split(":", 1)
            h[k.lower()] = v.strip()
        body = p.stdout.read(int(h["content-length"])).decode(errors="replace")
        print(stamp(), "got:", body[:400], flush=True)


threading.Thread(target=errs, daemon=True).start()
threading.Thread(target=outs, daemon=True).start()


def send(m):
    b = json.dumps(m).encode()
    p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b)
    p.stdin.flush()
    print(stamp(), "sent:", json.dumps(m)[:200], flush=True)


send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}, "rootUri": root}})
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "volt", "version": 1, "text": text}}})
send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/hover", "params": {"textDocument": {"uri": uri}, "position": {"line": 9, "character": 13}}})
time.sleep(90)
print(stamp(), "done waiting; server running:", p.poll() is None, flush=True)
p.kill()
