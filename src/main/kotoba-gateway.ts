import { app } from "electron";
import { profileHome } from "./utils";
import * as cljk from "./cljk/out/kotoba-desktop.js";

// @lat: [[gateway-hy#Desktop integration]]

// The logic lives in cljk (src/cljk/kotoba/desktop/gateway.cljk). This file
// adapts it to Electron and the TS utils: it supplies `app` facts and the
// profile home, and keeps the signatures the rest of the main process uses.

/**
 * Which process serves the local Hermes API for a profile: `hy` (default,
 * Kotoba's own gateway in `gateway-hy/`) or `hermes` (upstream
 * `hermes gateway`, via KOTOBA_GATEWAY_RUNTIME=hermes).
 */
export type GatewayRuntime = "hy" | "hermes";

export function gatewayRuntime(
  env: NodeJS.ProcessEnv = process.env,
): GatewayRuntime {
  return cljk.gatewayRuntime(env);
}

export function isHyGateway(env: NodeJS.ProcessEnv = process.env): boolean {
  return cljk.isHyGateway(env);
}

/** `gateway-hy/` next to the app: unpacked resources when packaged, repo root in dev. */
export function kotobaGatewayDir(): string {
  return cljk.gatewayDir(
    process.env,
    app.isPackaged,
    process.resourcesPath ?? "",
    app.getAppPath(),
  );
}

export function kotobaGatewayLauncher(): string {
  return cljk.gatewayLauncher(kotobaGatewayDir());
}

/** Missing-install message, or null when the Hy gateway can be spawned. */
export function kotobaGatewaySpawnError(): string | null {
  return cljk.gatewaySpawnError(kotobaGatewayDir()) ?? null;
}

/** Own pid file, so a running upstream `hermes gateway` is never mistaken for it. */
export function kotobaGatewayPidPath(profile?: string): string {
  return cljk.gatewayPidPath(profileHome(profile));
}

export function kotobaGatewayArgs(
  profile: string | undefined,
  port: number,
): string[] {
  return cljk.gatewayArgs(kotobaGatewayDir(), profileHome(profile), port);
}

/** Env overlay: the Hy gateway reads HERMES_HOME directly (no `--profile` flag). */
export function kotobaGatewayEnv(
  profile: string | undefined,
  hermesRepo: string,
): Record<string, string> {
  return cljk.gatewayEnv(profileHome(profile), hermesRepo);
}
