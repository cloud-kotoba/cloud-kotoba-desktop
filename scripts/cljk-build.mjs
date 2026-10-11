#!/usr/bin/env node
// Build the cljk half of the Electron main process.
//
//   node scripts/cljk-build.mjs          # mirror + shadow-cljs release
//   node scripts/cljk-build.mjs --mirror # mirror only
//
// shadow-cljs resolves namespaces only from .cljs/.cljc/.clj, so the .cljk
// sources under src/cljk are copied into the generated, git-ignored
// .cljk-build/src with the extension recorded in cljk-origin.edn (the same
// approach as cloud-murakumo's scripts/cljk-mirror.cljk). A .cljk file with no
// recorded origin is refused rather than guessed. The compiled ES module lands
// in src/main/cljk/out/ with the committed type declarations beside it.
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const srcRoot = join(root, "src", "cljk");
const mirrorRoot = join(root, ".cljk-build", "src");
const outDir = join(root, "src", "main", "cljk", "out");

// cljk-origin.edn is a flat {"path" "ext"} map; read it without an EDN parser.
const origins = Object.fromEntries(
  [
    ...readFileSync(join(root, "cljk-origin.edn"), "utf8").matchAll(
      /"([^"]+\.cljk)"\s+"(cljs|cljc|clj)"/g,
    ),
  ].map((m) => [m[1], m[2]]),
);

// Plain Node script linted with the TypeScript preset (see audit-production-dependencies.mjs).
// eslint-disable-next-line @typescript-eslint/explicit-function-return-type
function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

// Skip when nothing that feeds the build changed since the last one.
const inputs = [
  ...walk(srcRoot),
  join(root, "cljk-origin.edn"),
  join(root, "deps.edn"),
  join(root, "shadow-cljs.edn"),
].sort();
const hash = createHash("sha256");
for (const f of inputs) hash.update(relative(root, f)).update(readFileSync(f));
const digest = hash.digest("hex");
const stampFile = join(outDir, ".inputs-sha256");
const force = process.argv.includes("--force");
if (
  !force &&
  !process.argv.includes("--mirror") &&
  existsSync(join(outDir, "kotoba-desktop.js")) &&
  existsSync(stampFile) &&
  readFileSync(stampFile, "utf8").trim() === digest
) {
  console.log("cljk-build: up to date");
  process.exit(0);
}

rmSync(mirrorRoot, { recursive: true, force: true });
let mirrored = 0;
for (const file of walk(srcRoot).filter((f) => f.endsWith(".cljk"))) {
  const rel = relative(root, file);
  const ext = origins[rel];
  if (!ext) {
    console.error(
      `cljk-build: ${rel} has no entry in cljk-origin.edn; record its origin, do not guess`,
    );
    process.exit(2);
  }
  const target = join(mirrorRoot, relative(srcRoot, file)).replace(
    /\.cljk$/,
    `.${ext}`,
  );
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, readFileSync(file));
  mirrored += 1;
}
console.log(`cljk-build: mirrored ${mirrored} .cljk files`);
if (process.argv.includes("--mirror")) process.exit(0);

const r = spawnSync(
  "clojure",
  ["-M:cljs", "-m", "shadow.cljs.devtools.cli", "release", "desktop-main"],
  {
    cwd: root,
    stdio: "inherit",
  },
);
if (r.error || r.status !== 0) {
  console.error(
    `cljk-build: shadow-cljs failed${r.error ? `: ${r.error.message}` : ""}`,
  );
  process.exit(r.status || 1);
}
mkdirSync(outDir, { recursive: true });
copyFileSync(
  join(srcRoot, "kotoba-desktop.d.ts"),
  join(outDir, "kotoba-desktop.d.ts"),
);
// The module is ESM; say so, so Node and Vitest load it without reparsing.
writeFileSync(join(outDir, "package.json"), '{"type": "module"}\n');
writeFileSync(stampFile, `${digest}\n`);
console.log(
  `cljk-build: ${relative(root, join(outDir, "kotoba-desktop.js"))} ${existsSync(join(outDir, "kotoba-desktop.js")) ? "ok" : "MISSING"}`,
);
