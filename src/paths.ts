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
