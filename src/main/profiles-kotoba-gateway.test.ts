import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";

// The shard gateway (gateway-hy) writes kotoba-gateway.pid, not gateway.pid,
// and no upstream multiplexer record exists while it serves the profiles.
const { home, alive } = vi.hoisted(() => {
  /* eslint-disable @typescript-eslint/no-require-imports */
  const { mkdtempSync } = require("fs");
  const { tmpdir } = require("os");
  const path = require("path");
  /* eslint-enable @typescript-eslint/no-require-imports */
  return {
    home: mkdtempSync(path.join(tmpdir(), "kotoba-gw-")) as string,
    alive: new Set<number>(),
  };
});

vi.mock("./installer", () => ({
  HERMES_HOME: home,
  HERMES_PYTHON: "/nonexistent/python",
  hermesCliArgs: (args: string[] = []) => args,
  getEnhancedPath: () => process.env.PATH ?? "",
}));
vi.mock("./gateway-multiplex", () => ({ liveMultiplexer: () => null }));
vi.mock("./profile-cron", () => ({ readProfileCronState: () => null }));
vi.mock("./utils", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./utils")>()),
  pidIsAliveAs: (pid: number) => alive.has(pid),
}));

import { getProfileSummary, invalidateProfileCache } from "./profiles";

beforeEach(() => {
  rmSync(home, { recursive: true, force: true });
  mkdirSync(join(home, "profiles"), { recursive: true });
  writeFileSync(join(home, "config.yaml"), "model:\n  default: base\n");
  alive.clear();
  invalidateProfileCache();
});

afterEach(() => invalidateProfileCache());

describe("Kotoba Hy gateway status", () => {
  // @lat: [[profile-distribution#Desktop relief#Tests#The Hy shard gateway counts as the default's gateway]]
  it("reads kotoba-gateway.pid when there is no gateway.pid", async () => {
    writeFileSync(
      join(home, "kotoba-gateway.pid"),
      JSON.stringify({ pid: 4242, kind: "kotoba-gateway", runtime: "hy" }),
    );
    expect((await getProfileSummary("default"))?.gatewayRunning).toBe(false);
    alive.add(4242);
    invalidateProfileCache();
    expect((await getProfileSummary("default"))?.gatewayRunning).toBe(true);
  });
});
