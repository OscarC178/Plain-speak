import { test, expect } from 'bun:test';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { catalogue, DEFAULT_SETTINGS, loadSettings, saveSettings, settingsSchema, toRulesFile, type Settings } from './settings';
import { resolve } from './rules';
import { PRESETS } from './styles';

const rule = (fields: Partial<Settings['rules'][number]>) => ({ id: 'rule-1', ...fields });
const slack = { app: 'Slack', title: 'client-x (Channel) - Example - Slack' };

test('no settings file means the defaults: Plain reading, Clean drafts', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'plainspeak-settings-'));
  try {
    expect(await loadSettings(dir)).toEqual(DEFAULT_SETTINGS);
    const r = resolve(toRulesFile(DEFAULT_SETTINGS), { ...slack, mode: 'read' });
    expect(r.instructions[0]).toBe(PRESETS.find(p => p.id === 'plain')!.instructions);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('settings round-trip through a private file', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'plainspeak-settings-'));
  try {
    const saved = await saveSettings(dir, { ...DEFAULT_SETTINGS, read_style: 'adhd' });
    expect(await loadSettings(dir)).toEqual(saved);
    expect((await stat(join(dir, 'settings.json'))).mode & 0o777).toBe(0o600);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('a custom style can be the default and is offered after the presets', () => {
  const s: Settings = { ...DEFAULT_SETTINGS, read_style: 'custom-boss', custom_styles: [{ id: 'custom-boss', kind: 'read', name: 'For my boss', instructions: 'BOSS STYLE' }] };
  expect(resolve(toRulesFile(s), { ...slack, mode: 'read' }).instructions[0]).toBe('BOSS STYLE');
  const read = catalogue(s).read;
  expect(read.at(-1)).toMatchObject({ id: 'custom-boss', custom: true });
  expect(read[0].id).toBe('plain');
});

test('rules become matches: blank fields are not conditions, titles are literal, disabled rules are skipped', () => {
  const blank = { enabled: true, app: '', channel: '', title: '', person: '', sender_domain: '', thread: '', read_style: '', draft_style: '', sender: '', max_lines: null, instructions: '', notes: '' };
  const parsed = toRulesFile({ ...DEFAULT_SETTINGS, rules: [
    { ...blank, id: 'rule-a', name: 'Client', app: 'Slack', channel: 'client-x', read_style: 'key-points', sender: 'esl', max_lines: 3 },
    { ...blank, id: 'rule-b', name: 'Off', enabled: false, read_style: 'one-line' },
    { ...blank, id: 'rule-c', name: 'Dots', title: 'a.b (c)' },
  ] });
  expect(parsed.rules.map(r => r.name)).toEqual(['Client', 'Dots']);
  expect(parsed.rules[0].match).toEqual({ app: 'slack', channel: 'client-x' });
  expect(parsed.rules[1].match).toEqual({ title: 'a\\.b \\(c\\)' });
  const r = resolve(parsed, { ...slack, mode: 'read' });
  expect(r.instructions[0]).toBe(PRESETS.find(p => p.id === 'key-points')!.instructions);
  expect(r.instructions.join(' ')).toContain('second or third language');
  expect(r.max_lines).toBe(3);
});

test('mistakes are refused with plain messages', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'plainspeak-settings-'));
  try {
    await expect(saveSettings(dir, { ...DEFAULT_SETTINGS, custom_styles: [{ id: 'custom-x', kind: 'read', name: ' ', instructions: 'x' }] })).rejects.toThrow('Give the custom style a name');
    // Deleting a custom style that a rule still uses is caught.
    await expect(saveSettings(dir, { ...DEFAULT_SETTINGS, rules: [rule({ read_style: 'custom-gone' })] })).rejects.toThrow('reading style no longer exists');
    await expect(saveSettings(dir, { ...DEFAULT_SETTINGS, max_lines: 99 })).rejects.toThrow();
    await expect(saveSettings(dir, { ...DEFAULT_SETTINGS, surprise: true })).rejects.toThrow();
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('panel colours default to light and only accept the three choices', async () => {
  expect(DEFAULT_SETTINGS.theme).toBe('light');
  const dir = await mkdtemp(join(tmpdir(), 'plainspeak-settings-'));
  try {
    expect((await saveSettings(dir, { ...DEFAULT_SETTINGS, theme: 'system' })).theme).toBe('system');
    await expect(saveSettings(dir, { ...DEFAULT_SETTINGS, theme: 'neon' })).rejects.toThrow();
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('the reader name is optional, trimmed and reaches the rules engine', () => {
  expect(DEFAULT_SETTINGS.reader_name).toBe('');
  const named = settingsSchema.parse({ reader_name: '  Oscar Craven ' });
  expect(named.reader_name).toBe('Oscar Craven');
  expect(resolve(toRulesFile(named), { ...slack, mode: 'read' }).reader).toBe('Oscar Craven');
  expect(resolve(toRulesFile(DEFAULT_SETTINGS), { ...slack, mode: 'read' }).reader).toBeUndefined();
});
