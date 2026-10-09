/**
 * plainspeak rules engine.
 *
 * Rules decide HOW Claude rewrites what is on screen: which profile applies
 * (ESL sender, dyslexic text, AI drivel), how many lines the overlay may use,
 * and any extra instructions or notes for a given person, Slack channel,
 * thread, Gmail subject or sender domain.
 *
 * Resolution is split in two:
 *   - deterministic: keys the server can check from the capture alone
 *     (app, window title, derived channel/subject, captured text)
 *   - conditional:   keys only Claude can check by reading the screenshot
 *     (person, sender_domain). These are passed to Claude as "apply if the
 *     sender is X" so the model does the matching.
 */

export type Mode = "read" | "correct" | "draft";

export interface Capture {
  /** Frontmost application name as reported by macOS (e.g. "Google Chrome", "Slack"). */
  app: string;
  /** Window title. For Chrome this is the tab title. */
  title: string;
  mode: Mode;
  /** Selected or copied text, if the hotkey managed to grab any. */
  text?: string;
  /** True when a screenshot of the window came with the capture. */
  image?: boolean;
  /** Where the pointer was when the button was pressed, as fractions of the screenshot (0 to 1). */
  pointer?: { x: number; y: number; marked?: boolean };
}

export interface Match {
  /** Normalised app: "slack", "gmail", or any other lower-cased app name. */
  app?: string;
  /** Regex (case-insensitive) tested against the raw window title. */
  title?: string;
  /** Slack channel/DM name or Gmail subject, exact match after normalisation. */
  channel?: string;
  /** Regex tested against captured text when present. */
  text?: string;
  /** Conditional: sender display name as it appears on screen. */
  person?: string;
  /** Conditional: email domain of the sender (Gmail only). */
  sender_domain?: string;
  /** Conditional: free-text description of a thread for Claude to recognise. */
  thread?: string;
  /** Restrict a rule to one mode. */
  mode?: Mode;
}

export interface Profile {
  instructions: string;
  max_lines?: number;
}

export interface Rule {
  name?: string;
  match: Match;
  profile?: string;
  max_lines?: number;
  instructions?: string;
  notes?: string;
  /** A different style for this rule: replaces the default instructions for that mode. */
  read_instructions?: string;
  draft_instructions?: string;
}

export interface RulesFile {
  defaults: {
    max_lines: number;
    read_instructions: string;
    draft_instructions: string;
    correct_instructions?: string;
  };
  profiles: Record<string, Profile>;
  rules: Rule[];
}

export interface Resolved {
  app: string;
  channel?: string;
  mode: Mode;
  max_lines: number;
  /** Ordered instruction blocks: defaults first, then profiles, then rule-specific. */
  instructions: string[];
  notes: string[];
  /** Rules Claude must apply itself once it has identified the sender. */
  conditional: Array<{ rule: Rule; profile?: Profile }>;
  /** Names of the rules that matched deterministically, for debugging. */
  matched: string[];
}

const CONDITIONAL_KEYS: Array<keyof Match> = ["person", "sender_domain", "thread"];

/** Map a raw macOS app name plus window title onto "slack" | "gmail" | other. */
export function normaliseApp(app: string, title: string): string {
  const t = title.trim();
  if (/\s[-–|]\sSlack$/i.test(t) || /^slack$/i.test(app)) return "slack";
  if (/\s[-–|]\sGmail$/i.test(t) || /^mail$/i.test(app)) return "gmail";
  return app.trim().toLowerCase();
}

/**
 * Pull the channel / DM name out of a Slack title, or the subject out of a
 * Gmail title. Returns undefined when the title is an inbox or unknown.
 *
 * Slack titles look like:  "render-farm (Channel) - Northwind - Slack"
 *                          "Marco Rossi (DM) - Northwind - Slack"
 *                          "Thread in #render-farm - Northwind - Slack"
 * Gmail titles look like:  "Re: Dailies for shot 040 - you@example.com - Gmail"
 *                          "Inbox (3) - you@example.com - Gmail"
 */
export function deriveChannel(app: string, title: string): string | undefined {
  const parts = title.split(/\s[-–|]\s/);
  if (parts.length < 2) return undefined;
  let head = parts[0].trim();
  if (app === "slack") {
    head = head.replace(/^\(\d+\)\s*/, ""); // unread badge "(3) general"
    head = head.replace(/\s*\((Channel|DM|Group DM)\)\s*$/i, "");
    head = head.replace(/^Thread in\s+/i, "");
    return head.replace(/^#/, "").toLowerCase() || undefined;
  }
  if (app === "gmail") {
    if (/^(inbox|starred|sent|drafts|all mail|spam|bin|trash)\b/i.test(head)) return undefined;
    return head.replace(/^((re|fwd?|aw|wg):\s*)+/i, "").toLowerCase() || undefined;
  }
  return undefined;
}

function regexMatches(pattern: string, value: string | undefined): boolean {
  if (value === undefined) return false;
  try {
    return new RegExp(pattern, "i").test(value);
  } catch {
    // A malformed regex should never take the whole toolkit down; treat as literal.
    return value.toLowerCase().includes(pattern.toLowerCase());
  }
}

/** True when every deterministic key on the matcher agrees with the capture. */
function deterministicMatch(m: Match, cap: Capture, app: string, channel?: string): boolean {
  if (m.mode && m.mode !== cap.mode) return false;
  if (m.app && m.app.toLowerCase() !== app) return false;
  if (m.title && !regexMatches(m.title, cap.title)) return false;
  if (m.channel && m.channel.replace(/^#/, "").toLowerCase() !== channel) return false;
  if (m.text && !regexMatches(m.text, cap.text)) return false;
  return true;
}

function hasConditionalKeys(m: Match): boolean {
  return CONDITIONAL_KEYS.some((k) => m[k] !== undefined);
}

export function resolve(rules: RulesFile, cap: Capture): Resolved {
  const app = normaliseApp(cap.app, cap.title);
  const channel = deriveChannel(app, cap.title);
  const out: Resolved = {
    app,
    channel,
    mode: cap.mode,
    max_lines: rules.defaults.max_lines,
    instructions: [cap.mode === "draft" ? rules.defaults.draft_instructions : cap.mode === "correct" ? (rules.defaults.correct_instructions ?? "Correct spelling, grammar, word order and missing words in the visible message. Preserve the full meaning, names, dates, numbers and tone. Do not summarise or interpret motives. Return corrected text only. Flag ambiguous wording rather than guessing.") : rules.defaults.read_instructions],
    notes: [],
    conditional: [],
    matched: [],
  };

  for (const rule of rules.rules ?? []) {
    if (!deterministicMatch(rule.match, cap, app, channel)) continue;
    const profile = rule.profile ? rules.profiles?.[rule.profile] : undefined;
    if (rule.profile && !profile) {
      out.notes.push(`Rule "${rule.name ?? "unnamed"}" refers to unknown profile "${rule.profile}".`);
    }
    if (hasConditionalKeys(rule.match)) {
      out.conditional.push({ rule, profile });
      continue;
    }
    out.matched.push(rule.name ?? "unnamed");
    if (profile) {
      out.instructions.push(profile.instructions.trim());
      if (profile.max_lines !== undefined) out.max_lines = profile.max_lines;
    }
    const style = cap.mode === "read" ? rule.read_instructions : cap.mode === "draft" ? rule.draft_instructions : undefined;
    if (style) out.instructions[0] = style.trim();
    if (rule.instructions) out.instructions.push(rule.instructions.trim());
    if (rule.notes) out.notes.push(rule.notes.trim());
    if (rule.max_lines !== undefined) out.max_lines = rule.max_lines; // rule beats profile beats default
  }
  return out;
}
