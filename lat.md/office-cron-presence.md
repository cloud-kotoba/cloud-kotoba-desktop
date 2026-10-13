# Cron presence

The Office reads each profile's cron scheduler so a cron-driven bot's day of work — an attempt in flight, a run that failed, the next run — shows on its nameplate and in its details, instead of every bot standing idle.

This fork's fleet is ~90 profiles that each run one daily Hermes cron job and hold no resident gateway.

Upstream's rule ([[src/renderer/src/screens/Office/office3d/agents.ts#profileToOfficeAgent]]: a running Kanban card, else gateway liveness, else idle) drew all of them amber all day, and on 2026-09-22 drew the 57 whose morning run had failed (`screen-route-refused`, an api.kotoba.cloud outage) the same amber as the 25 that had succeeded. Measured that day.

## Reading a profile's cron state

The desktop summarizes durable cron state for each profile.

[[src/main/profile-cron.ts#readProfileCronState]] folds `<profile>/cron/jobs.json` (enabled jobs: `last_run_at`, `last_status`, `last_error`, `next_run_at`) into one state — the latest run and its status, the soonest next run, the failed job names — and [[src/main/profile-cron.ts#countRunningExecutions]] counts `claimed` / `running` rows in `cron/executions.db` (opened read-only with better-sqlite3). A profile without a cron directory is `null`; an unreadable `jobs.json` is zero jobs, never a throw. `listProfiles` carries it as `cron` on every local profile.

## Status rule

[[src/renderer/src/screens/Office/office3d/agents.ts#cronStatus]] says "working" for an attempt in flight, "error" for a failed last run, "idle" for a job that ran fine, and nothing for a profile without enabled jobs.

A running Kanban card — or, when Kanban is unavailable, a live gateway — still wins; cron speaks only when upstream's rule would say idle. The details sidebar in [[src/renderer/src/screens/Office/Office.tsx#Office]] shows the job count, in-flight count, last run (with ✓ or the failure and its reason) and next run.

## Deferring a restart

Incidental gateway restarts wait briefly for active cron work to finish.

Writing a credential restarts the profile's gateway so it picks the value up — and kills whatever that gateway is running: Hermes reports `Gateway shutdown (<phase>) killed the job's tool subprocess before the run finished.` Measured 2026-09-22: three profiles lost a daily run to exactly that message, one of them twice, on a day when a key was written while ~10 cron jobs were in flight across the fleet.

[[src/main/gateway-restart-defer.ts#restartGatewayWhenIdle]] holds an **incidental** restart until [[src/main/profile-cron.ts#countRunningExecutions]] reads zero for that profile, polling every 15 s for up to 10 minutes, then restarting anyway — a gateway holding a stale credential is its own failure, and waiting forever would hide it.

One deferral per profile, so a burst of env writes queues one restart rather than several. The nine incidental call sites in [[src/main/ipc/register.ts#registerIpcHandlers]] (env writes, model/provider changes, auxiliary config, platform config, this fork's Kotoba Cloud sign-in) route through it; the `restart-gateway` IPC the person triggers from Settings does not — a restart asked for happens when it is asked for. An unreadable `executions.db` reads as idle, so one broken file cannot freeze every future restart.

## Tests

[[src/main/profile-cron.test.ts]] writes real `jobs.json` files (both shapes) and a real sqlite `executions.db` into temp profiles and checks the fold, the in-flight count, and the no-throw on bad JSON.

[[src/main/gateway-restart-defer.test.ts]] drives the deferral with an injected clock, sleep and busy-probe: an idle profile restarts at once, a busy one waits and restarts when the job ends, a profile that never goes idle restarts once the cap expires, a burst queues one restart, two profiles defer independently, and a later write defers again. [[src/renderer/src/screens/Office/office3d/agents.test.ts]] covers the status rule: between runs idle, in flight working, failed run error, Kanban card wins, gateway wins only without Kanban, no cron keeps upstream's rule, and a cron change is a re-render.
