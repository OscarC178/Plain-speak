import { homedir } from 'node:os';
import { join } from 'node:path';

/**
 * Personal state (token, config, rules, temporary screenshots) lives outside the
 * checkout so every clone, branch and worktree shares one identity with Hammerspoon.
 * Override with PLAINSPEAK_HOME; tests pass their own directory.
 */
export function stateHome(): string {
  return process.env.PLAINSPEAK_HOME || join(homedir(), '.plainspeak');
}

/** First rules file that exists: personal (state dir), legacy in-repo copy, then the example. */
export async function rulesFile(root: string, stateDir: string): Promise<string> {
  for (const candidate of [join(stateDir, 'rules.yaml'), join(root, 'rules/rules.yaml')]) {
    if (await Bun.file(candidate).exists()) return candidate;
  }
  return join(root, 'rules/rules.example.yaml');
}
