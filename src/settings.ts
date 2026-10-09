import { z } from 'zod';
import { chmod, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { CORRECT, PRESETS, SENDERS, type StyleKind } from './styles';
import type { Match, RulesFile } from './rules';

/**
 * Settings edited in Plainspeak's settings window and saved to ~/.plainspeak/settings.json.
 * The service reads them on every capture, so a change applies from the next capture.
 * Empty strings mean "not set" so the form never has to juggle missing fields.
 */
const field = (max: number) => z.string().trim().max(max).default('');
const customStyle = z.object({
  id: z.string().regex(/^custom-[a-z0-9-]{1,40}$/),
  kind: z.enum(['read', 'draft']),
  name: z.string().trim().min(1, 'Give the custom style a name').max(60),
  instructions: z.string().trim().min(1, 'Describe how the custom style should look').max(4000),
}).strict();
const rule = z.object({
  id: z.string().regex(/^rule-[a-z0-9-]{1,40}$/),
  name: field(80),
  enabled: z.boolean().default(true),
  // When: matched by Plainspeak itself.
  app: field(80), channel: field(200), title: field(200),
  // Who: matched by Claude from the screenshot, best effort.
  person: field(120), sender_domain: field(120), thread: field(300),
  // Then: '' keeps the default style.
  read_style: field(60), draft_style: field(60), sender: field(40),
  max_lines: z.number().int().min(1).max(30).nullable().default(null),
  instructions: field(4000), notes: field(2000),
}).strict();

export const settingsSchema = z.object({
  // Light is dark text on off-white, as the BDA style guide prefers; system follows macOS.
  theme: z.enum(['light', 'dark', 'system']).default('light'),
  read_style: z.string().default('plain'),
  draft_style: z.string().default('clean'),
  max_lines: z.number().int().min(1).max(30).default(6),
  custom_styles: z.array(customStyle).max(50).default([]),
  rules: z.array(rule).max(200).default([]),
}).strict().superRefine((s, ctx) => {
  const known = (kind: StyleKind) => new Set([...PRESETS, ...s.custom_styles].filter(x => x.kind === kind).map(x => x.id));
  const read = known('read'), draft = known('draft'), senders = new Set(SENDERS.map(x => x.id));
  const issue = (path: (string | number)[], message: string) => ctx.addIssue({ code: z.ZodIssueCode.custom, path, message });
  if (!read.has(s.read_style)) issue(['read_style'], 'That reading style no longer exists');
  if (!draft.has(s.draft_style)) issue(['draft_style'], 'That draft style no longer exists');
  if (new Set(s.custom_styles.map(c => c.id)).size !== s.custom_styles.length) issue(['custom_styles'], 'Two custom styles share an id');
  s.rules.forEach((r, i) => {
    if (r.read_style && !read.has(r.read_style)) issue(['rules', i, 'read_style'], 'That reading style no longer exists');
    if (r.draft_style && !draft.has(r.draft_style)) issue(['rules', i, 'draft_style'], 'That draft style no longer exists');
    if (r.sender && !senders.has(r.sender)) issue(['rules', i, 'sender'], 'Unknown sender type');
  });
});
export type Settings = z.infer<typeof settingsSchema>;
export const DEFAULT_SETTINGS: Settings = settingsSchema.parse({});

export class SettingsError extends Error {}
const explain = (error: z.ZodError) => error.issues.map(i => i.message).join('. ');
export const settingsFile = (state: string) => join(state, 'settings.json');

export async function loadSettings(state: string): Promise<Settings> {
  const file = Bun.file(settingsFile(state));
  if (!(await file.exists())) return DEFAULT_SETTINGS;
  const parsed = settingsSchema.safeParse(await file.json());
  if (!parsed.success) throw new SettingsError(`Your settings could not be read: ${explain(parsed.error)}`);
  return parsed.data;
}

/** Validates and saves. Writes a temporary file first so a crash never leaves half a file. */
export async function saveSettings(state: string, input: unknown): Promise<Settings> {
  const parsed = settingsSchema.safeParse(input);
  if (!parsed.success) throw new SettingsError(explain(parsed.error));
  const path = settingsFile(state), temporary = `${path}.tmp`;
  await Bun.write(temporary, JSON.stringify(parsed.data, null, 2));
  await chmod(temporary, 0o600);
  await rename(temporary, path);
  return parsed.data;
}

/** What the settings window and the menu offer: built-in styles first, then yours. */
export function catalogue(s: Settings) {
  const list = (kind: StyleKind) => [
    ...PRESETS.filter(p => p.kind === kind).map(({ id, name, description }) => ({ id, name, description, custom: false })),
    ...s.custom_styles.filter(c => c.kind === kind).map(({ id, name }) => ({ id, name, description: 'Your own style', custom: true })),
  ];
  return { read: list('read'), draft: list('draft'), senders: SENDERS.map(({ id, name }) => ({ id, name })) };
}

const styleText = (s: Settings, id: string) => [...PRESETS, ...s.custom_styles].find(x => x.id === id)?.instructions;
const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Turns the settings into the form the rules engine resolves for each capture. */
export function toRulesFile(s: Settings): RulesFile {
  return {
    defaults: {
      max_lines: s.max_lines,
      read_instructions: styleText(s, s.read_style) ?? PRESETS[0].instructions,
      draft_instructions: styleText(s, s.draft_style) ?? PRESETS.find(p => p.id === 'clean')!.instructions,
      correct_instructions: CORRECT,
    },
    profiles: Object.fromEntries(SENDERS.map(x => [x.id, { instructions: x.instructions, max_lines: x.max_lines }])),
    rules: s.rules.filter(r => r.enabled).map(r => {
      // Unset fields must be absent, not empty, or they would count as conditions.
      const match = Object.fromEntries(Object.entries({
        app: r.app.toLowerCase(), channel: r.channel, title: r.title && escapeRegExp(r.title),
        person: r.person, sender_domain: r.sender_domain, thread: r.thread,
      }).filter(([, v]) => v)) as Match;
      return {
        name: r.name || 'Unnamed rule', match,
        profile: r.sender || undefined,
        max_lines: r.max_lines ?? undefined,
        instructions: r.instructions || undefined,
        notes: r.notes || undefined,
        read_instructions: r.read_style ? styleText(s, r.read_style) : undefined,
        draft_instructions: r.draft_style ? styleText(s, r.draft_style) : undefined,
      };
    }),
  };
}
