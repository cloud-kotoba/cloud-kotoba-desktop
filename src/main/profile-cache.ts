/**
 * Invalidation hook for the profile list cache in profiles.ts.
 *
 * The implementation is cljk (src/cljk/kotoba/desktop/profile_cache.cljk);
 * this module keeps the TS signatures for profiles.ts and profile-meta.ts.
 */
import * as cljk from "./cljk/out/kotoba-desktop.js";

/** Drop cached profile data. Without an id every profile is dropped. */
export function invalidateProfileCache(id?: string): void {
  cljk.invalidateProfileCache(id ?? null);
}

export function onProfileCacheInvalidated(
  listener: (id?: string) => void,
): () => void {
  return cljk.onProfileCacheInvalidated((id) => listener(id ?? undefined));
}
