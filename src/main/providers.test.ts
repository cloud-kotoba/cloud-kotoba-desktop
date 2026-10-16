import { describe, expect, it } from "vitest";
import { providerDoesNotNeedApiKey } from "./providers";

describe("providers without API keys", () => {
  // @lat: [[provider-setup#Keyless providers skip first-run setup#A named murakumo provider counts as configured]]
  it("treats murakumo like the other keyless providers", () => {
    expect(providerDoesNotNeedApiKey("murakumo")).toBe(true);
    expect(providerDoesNotNeedApiKey("custom")).toBe(true);
    expect(providerDoesNotNeedApiKey("openrouter")).toBe(false);
  });
});
