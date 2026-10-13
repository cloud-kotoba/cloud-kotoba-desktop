// @lat: [[kotoba-cloud-account#Kotoba Cloud account#Device sign-in]]
/**
 * The desktop's HTTP to kotoba.cloud.
 *
 * Sign-in is the device grant (kotoba-cloud-device.ts): the Passkey happens
 * in the person's own browser and this process ends up holding a scoped
 * personal API token (KOTOBA_API_KEY, in the OS keychain). Requests that act
 * as the person carry that token as a `bearer`. The cookie partition below is
 * what the earlier in-window Passkey sign-in left behind — a Passkey inside
 * an Electron window never reached the person's platform authenticator, so
 * that window is gone; the partition is still read (viewer) and cleared
 * (sign-out) so an old session does not linger.
 */
import { net, session, type Session } from "electron";

export const KOTOBA_CLOUD_PARTITION = "persist:kotoba-cloud";
export const KOTOBA_CLOUD_ORIGIN = "https://kotoba.cloud";
export const KOTOBA_APP_ORIGIN = "https://app.kotoba.cloud";
export const KOTOBA_SESSION_COOKIE = "gftd_session";

export interface KotobaCloudViewer {
  valid: boolean;
  username?: string | null;
  principalId?: string | null;
  accountDid?: string | null;
}

export class KotobaCloudSessionError extends Error {
  constructor(
    message: string,
    readonly code:
      | "sign-in-cancelled"
      | "sign-in-timeout"
      | "sign-in-required"
      | "request-failed"
      | string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "KotobaCloudSessionError";
  }
}

export function getKotobaCloudSession(): Session {
  return session.fromPartition(KOTOBA_CLOUD_PARTITION);
}

/** One JSON request against kotoba.cloud with the partition's cookies. */
export function requestKotobaCloudJson(
  url: string,
  options: {
    method?: "GET" | "POST" | "DELETE";
    body?: unknown;
    origin?: string;
    /** A `kc_pat_` sent as `Authorization: Bearer` — acting as the person. */
    bearer?: string | null;
    timeoutMs?: number;
  } = {},
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const request = net.request({
      method: options.method ?? "GET",
      redirect: "follow",
      session: getKotobaCloudSession(),
      url,
      useSessionCookies: true,
    });
    request.setHeader("Accept", "application/json");
    if (options.origin) request.setHeader("Origin", options.origin);
    if (options.bearer)
      request.setHeader("Authorization", `Bearer ${options.bearer}`);
    if (options.body !== undefined) {
      request.setHeader("Content-Type", "application/json");
    }
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      request.abort();
      reject(
        new KotobaCloudSessionError(
          `kotoba.cloud did not answer within ${options.timeoutMs ?? 15_000} ms: ${url}`,
          "request-failed",
        ),
      );
    }, options.timeoutMs ?? 15_000);
    timer.unref?.();
    request.on("response", (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      response.on("end", () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        const text = Buffer.concat(chunks).toString("utf8");
        let body: unknown = null;
        try {
          body = text ? JSON.parse(text) : null;
        } catch {
          body = { raw: text.slice(0, 200) };
        }
        resolve({ status: response.statusCode, body });
      });
      response.on("error", (error: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(new KotobaCloudSessionError(error.message, "request-failed"));
      });
    });
    request.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new KotobaCloudSessionError(error.message, "request-failed"));
    });
    if (options.body !== undefined) request.write(JSON.stringify(options.body));
    request.end();
  });
}

/** The signed-in viewer, or {valid:false} — never throws on a 401. */
export async function kotobaCloudViewer(): Promise<KotobaCloudViewer> {
  try {
    const { status, body } = await requestKotobaCloudJson(
      `${KOTOBA_CLOUD_ORIGIN}/v1/session`,
    );
    const v = (body ?? {}) as Record<string, unknown>;
    if (status !== 200 || v.valid !== true) return { valid: false };
    return {
      valid: true,
      username: typeof v.username === "string" ? v.username : null,
      principalId: typeof v.principalId === "string" ? v.principalId : null,
      accountDid: typeof v.accountDid === "string" ? v.accountDid : null,
    };
  } catch {
    return { valid: false };
  }
}

/** Forget the session: the partition's cookies go, nothing else. */
export async function signOutKotobaCloud(): Promise<void> {
  await getKotobaCloudSession().clearStorageData({ storages: ["cookies"] });
}
