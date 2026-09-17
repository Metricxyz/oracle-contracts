// SPDX-License-Identifier: MIT
/**
 * Guards the repo's agent-facing `skills/` directory (a sibling of this
 * package, not code inside it): asserts the expected 3 skill folders exist
 * and that every backtick-quoted repo-relative path referenced in each
 * SKILL.md's body actually exists on disk. This is a documentation-integrity
 * guard, not a wire-format test — it has no client-library dependency and
 * is unaffected by the ethers v6 migration.
 */
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const REPO_ROOT = fileURLToPath(new URL('../../..', import.meta.url));
const SKILLS_DIR = join(REPO_ROOT, 'skills');
// backtick-quoted repo-relative paths, e.g. `docs/anchored-price-provider-quickstart.md`
const PATH_RE = /`((?:contracts|docs|script|examples|skills|test)\/[^`\s]+)`/g;

describe('agent skills', () => {
  const names = readdirSync(SKILLS_DIR);

  it('expected skills exist', () => {
    expect(names.sort()).toEqual([
      'create-provider',
      'setup-compressed-pusher',
      'setup-pyth-relayer',
    ]);
  });

  for (const name of readdirSync(SKILLS_DIR)) {
    it(`${name}: frontmatter + all referenced paths exist`, () => {
      const body = readFileSync(join(SKILLS_DIR, name, 'SKILL.md'), 'utf8');
      const fm = body.match(/^---\n([\s\S]*?)\n---\n/);
      expect(fm, 'YAML frontmatter block').toBeTruthy();
      expect(fm![1]).toMatch(/^name:\s*\S+/m);
      expect(fm![1]).toMatch(/^description:\s*\S+/m);
      for (const m of body.matchAll(PATH_RE)) {
        const p = m[1].replace(/[.,;:]+$/, '');
        expect(existsSync(join(REPO_ROOT, p)), `referenced path missing: ${p}`).toBe(true);
      }
    });
  }
});
