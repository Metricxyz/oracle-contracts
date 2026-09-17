// SPDX-License-Identifier: MIT
/**
 * Tiny env-var helpers shared by every script/demo entry point.
 *
 * Purpose: give scripts one consistent, fail-fast way to read configuration
 * from `process.env` instead of ad hoc `process.env.X ?? 'default'` checks
 * scattered across the package.
 *
 * What happens inside: `requireEnv` throws immediately if a var is missing
 * or empty (fail fast, no silent `undefined` propagating into an RPC call);
 * `envOr`/`envInt` fall back to a caller-supplied default, with `envInt`
 * additionally validating the value parses as an integer.
 *
 * Inputs/outputs/env: reads arbitrary `process.env[name]`; the specific
 * variable names consumed by each script are documented in that script's own
 * header (e.g. `RPC_URL`, `PUSHER_PRIVATE_KEY`, `SLOT_INDEX`) and in
 * `.env.example`.
 *
 * Place in the package: pure Node/env plumbing with no client-library
 * dependency — unaffected by the ethers v6 migration (`src/common/clients.ts`
 * is the file that changed for that).
 */
export function requireEnv(name: string): string {
  const v = process.env[name];
  if (v === undefined || v === '') throw new Error(`missing required env var ${name}`);
  return v;
}

export function envOr(name: string, fallback: string): string {
  const v = process.env[name];
  return v === undefined || v === '' ? fallback : v;
}

export function envInt(name: string, fallback: number): number {
  const v = process.env[name];
  if (v === undefined || v === '') return fallback;
  const n = Number(v);
  if (!Number.isInteger(n)) throw new Error(`env var ${name}=${v} is not an integer`);
  return n;
}
