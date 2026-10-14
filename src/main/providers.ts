export const PROVIDERS_WITHOUT_API_KEYS = new Set([
  "custom",
  "lmstudio",
  "ollama",
  "vllm",
  "llamacpp",
  "openai-codex",
  // Murakumo fleet inference (api.murakumo.cloud) takes no key: its setup card
  // has needsKey: false, and a named `providers.murakumo` entry in config.yaml
  // must not send the user back to first-run setup for a key that does not exist.
  "murakumo",
]);

export function providerDoesNotNeedApiKey(provider: string): boolean {
  return PROVIDERS_WITHOUT_API_KEYS.has(provider);
}
