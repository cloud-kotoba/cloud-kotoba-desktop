#!/usr/bin/env node
// Helper for the Hy gateway in gateway-hy/.
//   deps   vendor Hy into gateway-hy/.deps for Hermes Agent's python
//   test   run the gateway contract tests (echo backend)
//   start  run the gateway against the local Hermes Agent install
//   hy2py  write the Python view of the Hy sources to gateway-hy/py/
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const gw = join(root, "gateway-hy");
const hermesHome = process.env.HERMES_HOME || join(homedir(), ".hermes");
const hermesRepo = process.env.HERMES_REPO || join(hermesHome, "hermes-agent");
// Same interpreter the desktop spawns (src/main/installer.ts HERMES_PYTHON).
const hermesPython =
  process.platform === "win32"
    ? join(hermesRepo, "venv", "Scripts", "python.exe")
    : join(hermesRepo, "venv", "bin", "python");
// HERMES_PYTHON wins as given (CI sets it to its own `python`). Otherwise use
// the Hermes interpreter when installed, and plain python3 on machines without
// Hermes: deps, test and hy2py need only Hy (+ cryptography for the tests).
const python =
  process.env.HERMES_PYTHON ||
  (existsSync(hermesPython) ? hermesPython : "python3");

// Hy tools run as `python -m hy tools/<x>.hy` with the vendored Hy on the path.
const hyEnv = {
  ...process.env,
  PYTHONPATH: [join(gw, ".deps"), gw, process.env.PYTHONPATH]
    .filter(Boolean)
    .join(":"),
};

// Plain Node script linted with the TypeScript preset (see audit-production-dependencies.mjs).
// eslint-disable-next-line @typescript-eslint/explicit-function-return-type
function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { stdio: "inherit", ...opts });
  if (r.error) {
    // A missing tool (e.g. no uv) is a failed step the caller can fall back from.
    console.error(`${cmd}: ${r.error.message}`);
    return 1;
  }
  return r.status ?? 1;
}

const cmd = process.argv[2];
let code = 0;
if (cmd === "deps") {
  // Hy and funcparserlib are pure Python, so any Python can vendor them:
  // the Hermes interpreter locally, plain python3 on a build machine.
  const target = join(gw, ".deps");
  const req = join(gw, "requirements.txt");
  code = run("uv", [
    "pip",
    "install",
    "--python",
    python,
    "--target",
    target,
    "-r",
    req,
  ]);
  if (code !== 0) {
    code = run(python, [
      "-m",
      "pip",
      "install",
      "--no-compile",
      "--target",
      target,
      "-r",
      req,
    ]);
  }
} else if (cmd === "test") {
  code = run(python, ["-m", "hy", join(gw, "tools", "run_tests.hy")], {
    env: hyEnv,
  });
} else if (cmd === "hy2py") {
  code = run(
    python,
    ["-m", "hy", join(gw, "tools", "hy2py.hy"), ...process.argv.slice(3)],
    { env: hyEnv },
  );
} else if (cmd === "start") {
  code = run(
    process.env.HERMES_PYTHON || hermesPython,
    [join(gw, "kotoba_gateway_main.py"), ...process.argv.slice(3)],
    {
      cwd: hermesRepo,
      env: { ...process.env, HERMES_HOME: hermesHome, HERMES_REPO: hermesRepo },
    },
  );
} else {
  console.error("usage: gateway-hy.mjs deps|test|start|hy2py [args]");
  code = 2;
}
process.exit(code);
