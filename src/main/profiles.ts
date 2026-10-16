import { execFileSync } from "child_process";
import { join } from "path";
import { homedir } from "os";
import { promises as fs } from "fs";
import { existsSync, mkdirSync, writeFileSync } from "fs";
import {
  HERMES_HOME,
  HERMES_PYTHON,
  hermesCliArgs,
  getEnhancedPath,
} from "./installer";
import {
  getActiveProfileNameSync,
  isValidNamedProfileName,
  isValidProfileName,
  pidIsAliveAs,
  profileHome,
  PROFILE_NAME_ERROR,
} from "./utils";
import { HIDDEN_SUBPROCESS_OPTIONS } from "./process-options";
import { liveMultiplexer } from "./gateway-multiplex";
import {
  invalidateProfileCache,
  onProfileCacheInvalidated,
} from "./profile-cache";
import { readProfileMeta, defaultColorForName } from "./profile-meta";
import { readProfileCronState, type ProfileCronState } from "./profile-cron";

const PROFILES_DIR = join(HERMES_HOME, "profiles");

function commandErrorMessage(err: unknown): string {
  const e = err as {
    stdout?: Buffer | string;
    stderr?: Buffer | string;
    message?: string;
  };
  const stdout = e.stdout?.toString().trim();
  const stderr = e.stderr?.toString().trim();
  return stdout || stderr || e.message || "Command failed";
}

export interface ProfileInfo {
  /** Stable internal profile id used for CLI, paths, routing, and persistence. */
  id: string;
  /** User-facing agent/profile name. */
  name: string;
  path: string;
  isDefault: boolean;
  isActive: boolean;
  model: string;
  provider: string;
  hasEnv: boolean;
  hasSoul: boolean;
  skillCount: number;
  gatewayRunning: boolean;
  /** This fork: true when the profile has no gateway of its own because the
   *  live default gateway serves it (gateway.multiplex_profiles). Still
   *  `gatewayRunning` — this only says WHICH process is serving it. */
  gatewayShared: boolean;
  /** This fork: the profile's cron scheduler state, or null without a
   *  cron directory (see profile-cron.ts). */
  cron: ProfileCronState | null;
  /** Resolved accent colour (stored override, else a stable default). */
  color: string;
  /** Avatar image as a data URL, or null when none is set. */
  avatar: string | null;
}

export interface CreateProfileResult {
  success: boolean;
  error?: string;
  id?: string;
}

const MAX_PROFILE_NAME_LENGTH = 80;

function normalizeAgentName(name: string): string {
  return name.trim().replace(/\s+/g, " ").slice(0, MAX_PROFILE_NAME_LENGTH);
}

function slugBaseForAgentName(name: string): string {
  const slug = normalizeAgentName(name)
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-+/g, "-")
    .slice(0, 48)
    .replace(/-+$/g, "");
  if (!slug || slug === "default" || !isValidNamedProfileName(slug)) {
    return "agent";
  }
  return slug;
}

function profileIdExists(id: string): boolean {
  return id === "default" || existsSync(join(PROFILES_DIR, id));
}

export function profileIdForAgentName(agentName: string): string {
  const base = slugBaseForAgentName(agentName);
  if (!profileIdExists(base)) return base;
  for (let i = 2; i < 1000; i += 1) {
    const suffix = `-${i}`;
    const candidate = `${base.slice(0, 64 - suffix.length)}${suffix}`;
    if (!profileIdExists(candidate)) return candidate;
  }
  return `${base.slice(0, 55)}-${Date.now().toString(36)}`;
}

async function readProfileConfig(profilePath: string): Promise<{
  model: string;
  provider: string;
}> {
  const configFile = join(profilePath, "config.yaml");
  try {
    const content = await fs.readFile(configFile, "utf-8");
    const modelMatch = content.match(/^\s*default:\s*["']?([^"'\n#]+)["']?/m);
    const providerMatch = content.match(
      /^\s*provider:\s*["']?([^"'\n#]+)["']?/m,
    );
    return {
      model: modelMatch ? modelMatch[1].trim() : "",
      provider: providerMatch ? providerMatch[1].trim() : "auto",
    };
  } catch {
    return { model: "", provider: "" };
  }
}

async function countSkills(profilePath: string): Promise<number> {
  const skillsDir = join(profilePath, "skills");
  try {
    const dirs = await fs.readdir(skillsDir);
    let count = 0;
    for (const d of dirs) {
      const sub = join(skillsDir, d);
      const stat = await fs.stat(sub);
      if (stat.isDirectory()) {
        const inner = await fs.readdir(sub);
        for (const f of inner) {
          try {
            await fs.access(join(sub, f, "SKILL.md"));
            count++;
          } catch {
            // not a skill
          }
        }
      }
    }
    return count;
  } catch {
    return 0;
  }
}

/** Is the profile's OWN gateway alive? Either upstream's gateway.pid or the
 *  Kotoba Hy gateway's kotoba-gateway.pid (the shard gateway that replaces
 *  upstream's multiplexer writes only the latter). The multiplexer case is
 *  answered from the per-scan snapshot before this is reached. */
async function ownGatewayRunning(profilePath: string): Promise<boolean> {
  for (const name of ["gateway.pid", "kotoba-gateway.pid"]) {
    if (await pidFileAlive(join(profilePath, name))) return true;
  }
  return false;
}

async function pidFileAlive(pidFile: string): Promise<boolean> {
  try {
    const raw = (await fs.readFile(pidFile, "utf-8")).trim();
    // The Python hermes CLI writes JSON: {"pid": <n>, "kind": ..., ...}.
    // Older builds wrote a bare integer, so fall back to parseInt.
    const parsed = raw.startsWith("{")
      ? (JSON.parse(raw) as { pid?: unknown }).pid
      : parseInt(raw, 10);
    const pid =
      typeof parsed === "number" && Number.isFinite(parsed) ? parsed : NaN;
    if (isNaN(pid)) return false;
    return pidIsAliveAs(pid, ["python", "pythonw"]);
  } catch {
    return false;
  }
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await fs.access(path);
    return true;
  } catch {
    return false;
  }
}

// @lat: [[profile-distribution#Desktop relief]]
// ── Scan cost control ────────────────────────────────────────────────────
// With ~1,000 profiles a full scan is the most expensive thing the desktop
// does, and several screens used to ask for one every few seconds (measured
// 2026-10-09: StatusBar and Office every 4 s, each scan opening ~1,015 cron
// sqlite files and re-reading gateway_state.json ~2,030 times on the main
// process). Three layers keep that bounded:
//   1. one scan at a time: concurrent callers share the in-flight promise;
//   2. a finished list is reused for LIST_TTL_MS; mutations invalidate it;
//   3. each profile's expensive fields are memoized until one of its files
//      changes (a few stats), so a fresh scan mostly reuses entries.

const LIST_TTL_MS = 3000;
/** Recompute an entry at least this often even if no watched file changed
 *  (a skill added inside a category dir does not touch skills/'s mtime). */
const ENTRY_MAX_AGE_MS = 60_000;

/** A profile's fields that do not depend on live gateway state. */
type ProfileBase = Omit<
  ProfileInfo,
  "isActive" | "gatewayRunning" | "gatewayShared"
>;

const entryCache = new Map<
  string,
  { sig: string; at: number; base: ProfileBase }
>();
let listCache: { at: number; gen: number; profiles: ProfileInfo[] } | null =
  null;
let listInFlight: { gen: number; promise: Promise<ProfileInfo[]> } | null =
  null;
let listGeneration = 0;

onProfileCacheInvalidated((id) => {
  listGeneration += 1;
  listCache = null;
  if (id) entryCache.delete(id);
  else entryCache.clear();
});

/** The live multiplexer's served set, read ONCE per scan. */
type MuxView = { served: Set<string> } | null;

function muxSnapshot(): MuxView {
  const record = liveMultiplexer();
  return record ? { served: new Set(record.served) } : null;
}

/** Same answer as multiplexerServes(): a live multiplexer always serves the
 *  default profile (it IS the default's gateway). */
function servedBy(mux: MuxView, id: string): boolean {
  if (!mux) return false;
  return id === "default" || mux.served.has(id);
}

async function mtimeOf(path: string): Promise<number> {
  try {
    return (await fs.stat(path)).mtimeMs;
  } catch {
    return -1;
  }
}

/** Cheap change detector for a profile: the mtimes of the files its
 *  expensive fields come from. The directory's own mtime covers .env /
 *  SOUL.md appearing or disappearing; the WAL covers cron executions. Skill
 *  changes are left to ENTRY_MAX_AGE_MS: five stats per profile instead of
 *  eight is a third less I/O per scan on a ~1,000-profile install. */
async function profileSignature(profilePath: string): Promise<string> {
  const parts = await Promise.all(
    [
      "",
      "config.yaml",
      "profile-meta.json",
      join("cron", "jobs.json"),
      join("cron", "executions.db-wal"),
    ].map((rel) => mtimeOf(rel ? join(profilePath, rel) : profilePath)),
  );
  return parts.join(":");
}

async function buildProfile(
  id: string,
  profilePath: string,
  isDefault: boolean,
  mux: MuxView,
): Promise<ProfileInfo> {
  const sig = await profileSignature(profilePath);
  let entry = entryCache.get(id);
  if (!entry || entry.sig !== sig || Date.now() - entry.at > ENTRY_MAX_AGE_MS) {
    const [config, hasEnv, hasSoul, skillCount, meta] = await Promise.all([
      readProfileConfig(profilePath),
      fileExists(join(profilePath, ".env")),
      fileExists(join(profilePath, "SOUL.md")),
      countSkills(profilePath),
      readProfileMeta(id),
    ]);
    entry = {
      sig,
      at: Date.now(),
      base: {
        id,
        name: meta.name || id,
        path: profilePath,
        isDefault,
        model: config.model,
        provider: config.provider,
        hasEnv,
        hasSoul,
        skillCount,
        // Synchronous (better-sqlite3), but only re-run when the cron files'
        // mtimes change, not on every scan.
        cron: readProfileCronState(profilePath),
        color: meta.color || defaultColorForName(id),
        avatar: meta.avatar || null,
      },
    };
    entryCache.set(id, entry);
  }
  // Under `gateway.multiplex_profiles` (the CLI default) no named profile owns
  // a gateway.pid — one default gateway serves them all and records which in
  // gateway_state.json. Ask that first, or every served profile reads "Off"
  // while its bots are online (measured 2026-09-22: 92 of 93).
  const served = servedBy(mux, id);
  return {
    ...entry.base,
    isActive: false,
    gatewayRunning: served || (await ownGatewayRunning(profilePath)),
    // Only a named profile can be served by ANOTHER process; the default's
    // multiplexer is its own gateway.
    gatewayShared: !isDefault && served,
  };
}

async function scanProfiles(): Promise<ProfileInfo[]> {
  const mux = muxSnapshot();
  const profiles: ProfileInfo[] = [
    // Default profile is HERMES_HOME itself
    await buildProfile("default", HERMES_HOME, true, mux),
  ];
  const seen = new Set<string>(["default"]);

  // Named profiles under ~/.hermes/profiles/
  if (existsSync(PROFILES_DIR)) {
    try {
      const dirs = await fs.readdir(PROFILES_DIR);
      const resolved = await Promise.all(
        dirs.map(async (name) => {
          // Skip dotfiles like .DS_Store so they don't get mistaken for profiles.
          if (name.startsWith(".")) return null;
          if (!isValidNamedProfileName(name)) return null;
          const profilePath = join(PROFILES_DIR, name);
          try {
            if (!(await fs.stat(profilePath)).isDirectory()) return null;
          } catch {
            return null;
          }
          // Any subdirectory of ~/.hermes/profiles/ is treated as a profile.
          // We deliberately do NOT require config.yaml or .env to exist —
          // a freshly created profile may have neither yet, and filtering on
          // them silently hides it from the UI (issue #19).
          seen.add(name);
          return buildProfile(name, profilePath, false, mux);
        }),
      );
      for (const p of resolved) {
        if (p) profiles.push(p);
      }
    } catch {
      // ignore
    }
  }

  // Forget entries for profiles that no longer exist.
  for (const id of entryCache.keys()) {
    if (!seen.has(id)) entryCache.delete(id);
  }
  return profiles;
}

/** Mark the active profile on a (possibly cached) list. Read live, so a
 *  profile switch needs no invalidation. */
function withActive(list: ProfileInfo[]): ProfileInfo[] {
  const active = getActiveProfileNameSync();
  return list.map((p) => ({ ...p, isActive: p.id === active }));
}

export { invalidateProfileCache };

export async function listProfiles(): Promise<ProfileInfo[]> {
  const gen = listGeneration;
  if (
    listCache &&
    listCache.gen === gen &&
    Date.now() - listCache.at < LIST_TTL_MS
  ) {
    return withActive(listCache.profiles);
  }
  if (!listInFlight || listInFlight.gen !== gen) {
    const promise = scanProfiles().then((profiles) => {
      if (gen === listGeneration) {
        listCache = { at: Date.now(), gen, profiles };
      }
      return profiles;
    });
    const flight = { gen, promise };
    listInFlight = flight;
    void promise.finally(() => {
      if (listInFlight === flight) listInFlight = null;
    });
  }
  return withActive(await listInFlight.promise);
}

/** One profile's info without scanning the rest — what the status bar and
 *  the post-switch gateway poll need. Null for an unknown profile. */
export async function getProfileSummary(
  id: string,
): Promise<ProfileInfo | null> {
  const isDefault = id === "default";
  if (!isDefault && !isValidNamedProfileName(id)) return null;
  const profilePath = isDefault ? HERMES_HOME : join(PROFILES_DIR, id);
  if (!isDefault) {
    try {
      if (!(await fs.stat(profilePath)).isDirectory()) return null;
    } catch {
      return null;
    }
  }
  const info = await buildProfile(id, profilePath, isDefault, muxSnapshot());
  return { ...info, isActive: id === getActiveProfileNameSync() };
}

export function createProfile(
  name: string,
  cloneFrom: string | null,
): CreateProfileResult {
  const agentName = normalizeAgentName(name);
  if (!agentName) {
    return { success: false, error: "Agent name is required" };
  }
  const id = profileIdForAgentName(agentName);
  // `cloneFrom` may be "default" (not a "named" profile) or any valid named
  // profile; reject anything else so it can't reach the CLI as an argument.
  if (
    cloneFrom &&
    cloneFrom !== "default" &&
    !isValidNamedProfileName(cloneFrom)
  ) {
    return { success: false, error: PROFILE_NAME_ERROR };
  }

  // `--clone-from <source>` copies that profile's config/keys/skills and
  // implies `--clone`; omitting it creates a fresh profile.
  const args = cloneFrom
    ? ["profile", "create", id, "--clone-from", cloneFrom]
    : ["profile", "create", id];

  try {
    execFileSync(HERMES_PYTHON, hermesCliArgs(args), {
      cwd: join(HERMES_HOME, "hermes-agent"),
      env: {
        ...process.env,
        PATH: getEnhancedPath(),
        HOME: homedir(),
        HERMES_HOME,
      },
      stdio: "pipe",
      timeout: 30000,
      ...HIDDEN_SUBPROCESS_OPTIONS,
    });
  } catch (err) {
    return { success: false, error: commandErrorMessage(err) };
  }

  try {
    mkdirSync(profileHome(id), { recursive: true });
    writeFileSync(
      join(profileHome(id), "profile-meta.json"),
      JSON.stringify({ name: agentName }, null, 2),
      "utf-8",
    );
  } catch (err) {
    console.warn(
      `Created profile "${id}" but failed to write profile metadata:`,
      err,
    );
  }

  invalidateProfileCache(id);
  return { success: true, id };
}

export function deleteProfile(name: string): {
  success: boolean;
  error?: string;
} {
  if (name === "default")
    return { success: false, error: "Cannot delete the default profile" };
  if (!isValidNamedProfileName(name)) {
    return { success: false, error: PROFILE_NAME_ERROR };
  }

  try {
    execFileSync(
      HERMES_PYTHON,
      hermesCliArgs(["profile", "delete", name, "--yes"]),
      {
        cwd: join(HERMES_HOME, "hermes-agent"),
        env: {
          ...process.env,
          PATH: getEnhancedPath(),
          HOME: homedir(),
          HERMES_HOME,
        },
        stdio: "pipe",
        timeout: 30000,
        ...HIDDEN_SUBPROCESS_OPTIONS,
      },
    );
    if (existsSync(profileHome(name))) {
      return {
        success: false,
        error:
          "The profile directory still exists after deletion. Stop processes using it and retry.",
      };
    }
    invalidateProfileCache(name);
    return { success: true };
  } catch (err) {
    return { success: false, error: commandErrorMessage(err) };
  }
}

export function setActiveProfile(name: string): void {
  if (!isValidProfileName(name)) {
    throw new Error(PROFILE_NAME_ERROR);
  }

  try {
    execFileSync(HERMES_PYTHON, hermesCliArgs(["profile", "use", name]), {
      cwd: join(HERMES_HOME, "hermes-agent"),
      env: {
        ...process.env,
        PATH: getEnhancedPath(),
        HOME: homedir(),
        HERMES_HOME,
      },
      stdio: "pipe",
      timeout: 10000,
      ...HIDDEN_SUBPROCESS_OPTIONS,
    });
  } catch {
    // ignore — verified and repaired below
  }

  // The CLI validates against LOCAL profiles and raises when the name exists
  // only on the SSH/remote host (or when there is no local install at all).
  // That failure is swallowed above, so before this fallback the selection
  // silently never persisted: ~/.hermes/active_profile kept its old value,
  // every relaunch reset the UI to `default`, and activeSshProfile() scoped
  // the unified SSH dashboard's data to the wrong profile. The desktop's
  // source of truth is the local active_profile file (getActiveProfileNameSync),
  // so when the CLI didn't move it, write it directly — `name` is already
  // validated, and "default" is a plain value here (readers treat a missing
  // file and the literal "default" identically).
  if (getActiveProfileNameSync() !== name) {
    try {
      mkdirSync(HERMES_HOME, { recursive: true });
      writeFileSync(join(HERMES_HOME, "active_profile"), `${name}\n`);
    } catch {
      // Filesystem write failed — nothing else to fall back to; the CLI
      // attempt above already didn't persist it either.
    }
  }
}
