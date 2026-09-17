// SPDX-License-Identifier: MIT
/**
 * Toolchain canary: proves vitest actually runs under ESM with native
 * bigint support before any real test file's failure could be confused with
 * a broken harness. Deliberately has zero dependency on this package's own
 * code or its client library — if this test fails, the problem is the test
 * runner/config, not the migration.
 */
import { describe, expect, it } from 'vitest';

describe('toolchain smoke', () => {
  it('runs vitest with ESM + bigint', () => {
    expect((1n << 56n) - 1n).toBe(72057594037927935n);
  });
});
