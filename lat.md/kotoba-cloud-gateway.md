# Kotoba Cloud gateway

The gateway kotoba.cloud provides is the person's own Hermes running in a per-user Modal sandbox behind `app.kotoba.cloud`;

the account card launches, opens and stops it as the person — the profile's personal API token as a bearer, minted by the device grant with the `sandbox` scope.

`cloud-kotoba/app-hermes-sandbox` (2026-09-22) runs one sandbox per kotoba.cloud principal with the stock Hermes dashboard on loopback and a gate on the encrypted tunnel;

`app-kotoba-cloud` fronts it as `/v1/sandbox/session` — `POST` launches or resumes (one flat charge from ai credit), `GET` reports, `DELETE` stops — and returns the sandbox's tunnel URL with a signed, expiring `?hs=` handoff. Sessions end after 3 hours.

## Session lane

[[src/main/kotoba-cloud-gateway.ts#gatewayRequestAs]] binds every call to the active profile's token (`Authorization: Bearer kc_pat_…`;

a token without the `sandbox` scope is refused by name as `token-scope-insufficient`). [[src/main/kotoba-cloud-gateway.ts#kotobaGatewayStatus]] reads the lane: `{running:false}` is stopped, a URL is running, 401 is `signed-out`, 404 is `sandbox-session-not-deployed` (the lane was still on a branch when this landed — the card says so instead of pretending). [[src/main/kotoba-cloud-gateway.ts#launchKotobaGateway]] POSTs with `Origin: https://app.kotoba.cloud` and an empty JSON body, then polls GET every 5 s while the server says `starting` (cold image pull), up to 150 s; a refusal (`usage-limit-exceeded`, `billing-not-configured`, `sandbox-gateway-unavailable`) is returned by name and never retried into a second charge. [[src/main/kotoba-cloud-gateway.ts#stopKotobaGateway]] DELETEs.

## Opening it

[[src/main/kotoba-cloud-gateway.ts#openKotobaGatewayWindow]] loads the handoff URL in one window on `persist:kotoba-cloud-gateway`, so the gate's `hs` cookie, the dashboard's WebSockets and its terminal all stay same-origin against the sandbox.

This is the cloud gateway in the app; it is not the desktop's native chat transport. Retargeting that transport at the sandbox would need a cookie-carrying remote mode (upstream's Remote transport is token-or-OAuth, and the sandbox pairs a cookie gate with a loopback-mode dashboard) — named here as the follow-up, not claimed.

## Tests

Scripted requests verify reads, launches, polling, deadlines and refusal handling.

[[src/main/kotoba-cloud-gateway.test.ts]] drives the lane with a scripted request function: stopped / running / signed-out / not-deployed reads, a launch that returns ready, a launch that polls through `starting` with injected sleep and clock, the deadline, a 402 refusal that does not poll, the 401 that becomes `sign-in-required`, and DELETE with a refusal by name.
