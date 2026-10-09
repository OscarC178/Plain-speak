import { describe, expect, test } from "bun:test";
import { deriveChannel, loadRules, normaliseApp, resolve, type RulesFile } from "./rules";

// Minimal in-memory rules file used by most tests so they don't depend on the example YAML.
const base: RulesFile = {
  defaults: { max_lines: 6, read_instructions: "READ", draft_instructions: "DRAFT" },
  profiles: {
    esl: { instructions: "ESL" },
    drivel: { instructions: "DRIVEL", max_lines: 4 },
  },
  rules: [
    { name: "farm", match: { app: "slack", channel: "render-farm" }, max_lines: 3, notes: "job ids" },
    { name: "marco", match: { app: "slack", person: "Marco Rossi" }, profile: "esl" },
    { name: "ai-tabs", match: { app: "google chrome", title: "ChatGPT" }, profile: "drivel" },
    { name: "drafts", match: { mode: "draft" }, instructions: "DYSLEXIA" },
    { name: "bad", match: { app: "gmail" }, profile: "missing" },
  ],
};

describe("normaliseApp", () => {
  test("Slack in Chrome is detected from the tab title", () => {
    expect(normaliseApp("Google Chrome", "general (Channel) - Northwind - Slack")).toBe("slack");
  });
  test("Gmail in Chrome is detected from the tab title", () => {
    expect(normaliseApp("Google Chrome", "Inbox (2) - you@example.com - Gmail")).toBe("gmail");
  });
  test("anything else is the lower-cased app name", () => {
    expect(normaliseApp("Google Chrome", "ChatGPT")).toBe("google chrome");
  });
});

describe("deriveChannel", () => {
  test("Slack channel, DM, unread badge and thread titles", () => {
    expect(deriveChannel("slack", "render-farm (Channel) - Northwind - Slack")).toBe("render-farm");
    expect(deriveChannel("slack", "Marco Rossi (DM) - Northwind - Slack")).toBe("marco rossi");
    expect(deriveChannel("slack", "(3) general (Channel) - Northwind - Slack")).toBe("general");
    expect(deriveChannel("slack", "Thread in #render-farm - Northwind - Slack")).toBe("render-farm");
  });
  test("Gmail subject strips Re/Fwd, inbox yields nothing", () => {
    expect(deriveChannel("gmail", "Re: Fwd: Dailies for 040 - o@x.com - Gmail")).toBe("dailies for 040");
    expect(deriveChannel("gmail", "Inbox (3) - o@x.com - Gmail")).toBeUndefined();
  });
});

describe("resolve", () => {
  test("defaults apply when nothing matches", () => {
    const r = resolve(base, { app: "Google Chrome", title: "Some page", mode: "read" });
    expect(r.max_lines).toBe(6);
    expect(r.instructions).toEqual(["READ"]);
    expect(r.matched).toEqual([]);
  });

  test("channel rule overrides max_lines and adds notes", () => {
    const r = resolve(base, { app: "Google Chrome", title: "render-farm (Channel) - X - Slack", mode: "read" });
    expect(r.channel).toBe("render-farm");
    expect(r.max_lines).toBe(3);
    expect(r.notes).toContain("job ids");
    expect(r.matched).toEqual(["farm"]);
  });

  test("person rules are conditional, not applied by the server", () => {
    const r = resolve(base, { app: "Google Chrome", title: "general (Channel) - X - Slack", mode: "read" });
    expect(r.conditional.map((c) => c.rule.name)).toEqual(["marco"]);
    expect(r.conditional[0].profile?.instructions).toBe("ESL");
    expect(r.instructions).not.toContain("ESL");
  });

  test("profile max_lines applies, and rule max_lines beats profile", () => {
    const viaProfile = resolve(base, { app: "Google Chrome", title: "ChatGPT", mode: "read" });
    expect(viaProfile.max_lines).toBe(4);
    const rules: RulesFile = { ...base, rules: [{ match: { title: "ChatGPT" }, profile: "drivel", max_lines: 2 }] };
    expect(resolve(rules, { app: "Google Chrome", title: "ChatGPT", mode: "read" }).max_lines).toBe(2);
  });

  test("draft mode uses draft defaults and mode-scoped rules", () => {
    const r = resolve(base, { app: "Google Chrome", title: "general (Channel) - X - Slack", mode: "draft", text: "hte thing" });
    expect(r.instructions[0]).toBe("DRAFT");
    expect(r.instructions).toContain("DYSLEXIA");
  });

  test("unknown profile is reported, not fatal", () => {
    const r = resolve(base, { app: "Google Chrome", title: "Re: hi - o@x.com - Gmail", mode: "read" });
    expect(r.notes.join(" ")).toMatch(/unknown profile "missing"/);
  });
});

describe("loadRules", () => {
  test("the shipped example file parses and resolves", async () => {
    const rules = await loadRules(new URL("../rules/rules.example.yaml", import.meta.url).pathname);
    expect(Object.keys(rules.profiles)).toEqual(["ai-drivel", "esl", "dyslexic"]);
    const r = resolve(rules, { app: "Google Chrome", title: "render-farm (Channel) - Northwind - Slack", mode: "read" });
    expect(r.max_lines).toBe(3);
  });
});
