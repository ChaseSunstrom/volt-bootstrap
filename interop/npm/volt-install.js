// An npm package's install script for a Volt library: `npm install` builds it with bolt, as
// volt-build does for Cargo. Copy this file into the package (next to its bolt.toml, whose [lib]
// has kind "shared" and bindings "node", "js" and "ts") and name it in package.json:
//
//     "main": "target/release/bindings/NAME.js",
//     "types": "target/release/bindings/NAME.d.ts",
//     "scripts": { "install": "node volt-install.js" }
//
// bolt build --release writes NAME.js, its types and NAME.node (the addon, compiled against Node's
// headers, which finds libNAME.so through its rpath). bolt comes from $BOLT, else the PATH; it finds
// voltc as it always does.
"use strict";
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

// [package]'s name: up to the next table ([package] # a comment, name = "x" or 'x')
const pkg = (/^\[package\][ \t]*(?:#.*)?$([^]*?)(?=^\[|(?![^]))/m.exec(fs.readFileSync("bolt.toml", "utf8")) || [])[1] || "";
const name = (/^\s*name\s*=\s*(?:"([^"]+)"|'([^']+)')/m.exec(pkg) || []).slice(1).find(Boolean);
if (!name) {
    console.error("volt-install: can't read the name in bolt.toml's [package]");
    process.exit(1);
}
const bolt = process.env.BOLT || "bolt";
const r = spawnSync(bolt, ["build", "--release"], { stdio: "inherit" });
if (r.error) {
    console.error(`volt-install: can't run ${bolt} (put bolt on the PATH, or set $BOLT to it): ${r.error.message}`);
    process.exit(1);
}
if (r.status !== 0) {
    process.exit(r.status || 1);
}
const addon = path.join("target", "release", "bindings", `${name}.node`);
if (!fs.existsSync(addon)) {
    console.error(`volt-install: bolt built no ${addon}: bolt.toml's [lib] needs kind "shared" and bindings "node" and "js", and Node's headers (node_api.h) have to be installed`);
    process.exit(1);
}
