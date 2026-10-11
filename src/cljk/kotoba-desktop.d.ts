// Types of the ES module shadow-cljs builds from src/cljk (build
// desktop-main). Copied next to the compiled module by scripts/cljk-build.mjs;
// edit here, not in src/main/cljk/out/.

/** kotoba.desktop.gateway */
export function gatewayRuntime(
  env: NodeJS.ProcessEnv | Record<string, string | undefined>,
): "hy" | "hermes";
export function isHyGateway(
  env: NodeJS.ProcessEnv | Record<string, string | undefined>,
): boolean;
export function gatewayDir(
  env: NodeJS.ProcessEnv | Record<string, string | undefined>,
  packaged: boolean,
  resourcesPath: string,
  appPath: string,
): string;
export function gatewayLauncher(dir: string): string;
export function gatewaySpawnError(dir: string): string | null;
export function gatewayPidPath(profileHome: string): string;
export function gatewayArgs(
  dir: string,
  profileHome: string,
  port: number,
): string[];
export function gatewayEnv(
  profileHome: string,
  hermesRepo: string,
): Record<string, string>;

/** kotoba.desktop.profile-cache */
export function invalidateProfileCache(id?: string | null): void;
export function onProfileCacheInvalidated(
  listener: (id?: string | null) => void,
): () => void;
