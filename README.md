# Plainspeak

A plain-English overlay for macOS. Press a mouse side button on a message that
takes too much work to read, and a small panel tells you what it means. Press the
other button and it fixes the wording. Nothing is ever sent for you.

![Plainspeak: less wording, more meaning](docs/images/hero.png)

It helps with AI filler, awkward wording across languages, and spelling, swapped
letters or missing words. It runs on **Claude Haiku 5.5** through your Claude Code
subscription login. No API keys. macOS only.

## Why use it

Some messages take more work to read than they should. Plainspeak does that work
on the screen you already have open.

- **Get the point fast.** Long, padded or AI-written messages come back as the
  point, what they want from you, the deadline and anything unclear.
- **Read across languages.** Awkward wording from someone writing in a second
  language is read for what they meant.
- **Easier to read.** Short parts, bold labels and clear gaps between them,
  following the British Dyslexia Association's style guide.
- **Check your own writing.** Your drafts come back with spelling, swapped letters
  and missing words fixed, in your own voice.
- **You stay in control.** It reads only when you press a button. It never sends,
  replies or edits anything for you.

## What it does

**Read.** Point at a message and press the back side button. It captures the
focused window and explains the message under the pointer: the point, what they
want from you, any deadline, and what is unclear. Each part gets its own short
paragraph. The panel opens beside the pointer. Real output from Haiku 5.5:

![A wordy message on the left; the plain-English reading on the right](docs/images/read-before-after.png)

**Correct.** The front side button fixes spelling, grammar and word order in the
visible message without summarising it:

![A message with spelling mistakes on the left; the corrected version on the right](docs/images/correct-before-after.png)

**Your own drafts.** Select text you wrote and press Control + Option + Command + D.
You get a correction to review, paste and send yourself:

![Illustration: a draft with spelling mistakes and its correction](docs/images/drafts.png)

**Context.** Command + back side button also searches your Obsidian notes and
Google Drive, and cites what it used.

## Controls

| Input | Action |
| --- | --- |
| Front side button | Read the visible message and correct its spelling and grammar |
| Back side button | Read and simplify the visible message |
| Command + back side button | Simplify, with context from your notes and Google Drive |
| Control + Option + Command + R | Same as the back side button |
| Control + Option + Command + D | Correct the text you have selected (your own draft) |
| Control + Option + Command + G | Same as Command + back side button |
| Escape, or click anywhere else once the result shows | Close the overlay |

A **PS** item in the menu bar offers the same actions, plus **Set front mouse
button…** and **Set back mouse button…** for mice that number their buttons
differently. The assigned side buttons stop working as browser Back and Forward.
With any other modifier held they behave normally.

## How it works

```mermaid
flowchart LR
  A[Side button or hotkey] --> B[Hammerspoon<br/>plainspeak.lua]
  B -- screenshot or selected text --> C[Local service<br/>127.0.0.1:8790]
  C -- capture and screenshot --> D[Warm Claude session<br/>Agent SDK, Claude Haiku 5.5]
  D -- answer as it is written --> C
  C --> E[Overlay panel]
```

1. Hammerspoon captures the focused window, or your selected text for drafts.
2. It posts the capture to a small Bun service on `127.0.0.1`, authenticated
   with a local token.
3. The service hands the capture, screenshot included, to a Claude session that
   it keeps warm through the Claude Agent SDK, signed in with your Claude plan.
4. Claude's answer streams back, and the panel shows the words as they arrive.
5. Every 15 captures the session is replaced, in the background, to keep it small.

Normal reads run with no tools at all. A context lookup (Command + back button)
gets its own short session that can only read your Obsidian notes and Google
Drive. Sending, sharing, writing and shell commands are blocked.

## What you need

Install these before you start. The commands use [Homebrew](https://brew.sh/).

| What | Why Plainspeak needs it | How to install |
| --- | --- | --- |
| macOS 13 or later | Claude Code needs it | - |
| Xcode Command Line Tools | `git` to clone the repo, `python3` for the installer | `xcode-select --install` |
| [Hammerspoon](https://www.hammerspoon.org/) | Watches the buttons and hotkeys, takes the screenshot, shows the panel | `brew install --cask hammerspoon` |
| [Bun](https://bun.sh/) | Runs the small local service | `brew install oven-sh/bun/bun` |
| [Claude Code](https://code.claude.com/docs/en/setup) | Signs you in to your Claude plan. Plainspeak runs Claude through that login | `brew install --cask claude-code` |
| A Claude Pro, Max, Team or Enterprise plan | Plainspeak uses your plan, not an API key. The free plan has no Claude Code | Run `claude` once and sign in |
| A mouse with side buttons (optional) | The quickest way to use it. Hotkeys work without one | - |

Hammerspoon also needs two macOS permissions, **Accessibility** and **Screen
Recording**. Step 3 of the setup covers them.

## Set up

**1. Clone and install.** Use a clone you will keep. Hammerspoon loads its script
from this folder.

```sh
git clone https://github.com/OscarC178/Plain-speak.git
cd Plain-speak
bun install
```

**2. Create your personal rules** (optional, the example works as it is):

```sh
mkdir -p ~/.plainspeak
cp rules/rules.example.yaml ~/.plainspeak/rules.yaml
bun run rules:check
```

**3. Install the Hammerspoon module.** This links `plainspeak.lua` into
`~/.hammerspoon` and adds `require("plainspeak")` to your `init.lua`. It refuses
to overwrite an existing, unrelated `plainspeak.lua`.

```sh
bun run install:hammerspoon
```

Open Hammerspoon and grant it **Accessibility** and **Screen Recording** in
System Settings > Privacy & Security. Then quit and reopen Hammerspoon. Reload
Config is not enough: it reloads the Lua but the running process keeps its old
permissions.

**4. Start Plainspeak.**

```sh
bun run start
```

There are no prompts to answer. After a few seconds you should see
`Claude session ready.` The PS item appears in the menu bar. Focus a message and
press a side button.

## Run it

Plainspeak runs on port 8790, so only one copy runs at a time.

**From a terminal.** `bun run start`. Control + C stops it. The terminal shows
when the session is ready and how long each answer took, never the content.

**From Slipway.** Nothing to configure. Add the repo, open any branch or
worktree, and press **Start dev server** in the Run panel. With no Dev Start
Command saved, Slipway runs `npm run dev`, which starts Plainspeak the same way.
Stopping the tab stops it. A fresh worktree installs its dependencies on first
run. Every branch runs its own copy of the code, so only start branches you trust.

**At login.**

```sh
bun run install:launchd     # start at login, and restart if it ever stops
bun run uninstall:launchd
```

The log is in `~/.plainspeak/launchd.log`.

**The old tmux engine.** The previous engine, a Claude Code session in tmux
using channels, still works for now with `bun run daemon:start`. It needs tmux
and its first-run prompts, and it will be removed in a later version. Stop it
with `bun run daemon:stop` before running `bun run start`.

## How to use it

### Read a message

1. Open the message in any app: Slack, Gmail, Teams or a web page.
2. Put the pointer on the message you mean. Plainspeak explains that one and uses
   the rest of the screen only as background.
3. Press the **back** side button, or Control + Option + Command + R.
4. A panel opens beside the pointer with up to four short parts: **The point**,
   **They want**, **By** and **Unclear**. Parts that do not apply are left out.
5. Click anywhere else, or press Escape, to close it. **Copy** keeps the text.

### Fix the wording of someone else's message

Point at it and press the **front** side button. You get the same message with
spelling, grammar and word order fixed. Nothing is summarised.

### Check your own draft before you send it

1. Write your message as normal.
2. Select the text.
3. Press Control + Option + Command + D.
4. The corrected version appears in the panel and is copied to your clipboard.
5. Paste it over your draft, read it once, and send it yourself.

### Bring in background from your notes

Hold Command and press the back side button. Plainspeak also searches your
Obsidian notes and Google Drive, and lists what it used. Use it for messages that
assume you remember earlier work.

### Which one to use

| You want to | Use |
| --- | --- |
| Understand a long, vague or AI-written message | Back side button |
| Read a message full of typos | Front side button |
| Tidy your own reply before sending | Select it, then Control + Option + Command + D |
| Understand a message that refers to earlier work | Command + back side button |

### Good habits

- Treat the panel as a reading aid, not the record. Check dates, numbers and
  commitments in the original before you act.
- When a part says **Unclear**, ask the sender rather than guess.
- Point before you press. With several messages on screen, the pointer is how
  Plainspeak knows which one you mean.
- Do not capture anything you could not share with Anthropic. The screenshot goes
  to Claude through your account.

## Configure

### Model and effort

The session runs `claude-haiku-5-5` at `high` effort by default. Override
either when starting:

```sh
PLAINSPEAK_MODEL=claude-opus-5-5 PLAINSPEAK_EFFORT=high bun run start
```

Stop Plainspeak first; a running copy keeps its model.

### Personal files

Everything personal lives in `~/.plainspeak`, outside the repo, so every clone,
branch and worktree shares it. Set `PLAINSPEAK_HOME` to use another folder.

| File | Purpose |
| --- | --- |
| `token` | Shared secret between Hammerspoon and the service. Created on first start. |
| `config.json` | Optional. `{"vault": "/absolute/path/to/your/vault"}` enables notes search. |
| `rules.yaml` | Optional. Your rules. Falls back to `rules/rules.example.yaml`. |
| `*.png` | Temporary screenshots, deleted after each result or timeout. |
| `launchd.log` | Output from the login item, if installed. |

Mouse button IDs are stored in `~/.hammerspoon/plainspeak-mouse.json`.

### Rules

Rules adapt the output per app, channel, person or thread. Changes are read on
the next capture.

![Illustration: a per-person rule clarifying awkward wording](docs/images/rules.png)
 Invalid YAML, unknown profiles or bad line limits fail visibly.
The example includes `ai-drivel`, `esl` and `dyslexic` profiles. Assign a profile
only when you know it fits; Plainspeak does not diagnose anyone.

```yaml
rules:
  - name: Short replies for this channel
    match: { app: slack, channel: planning }
    max_lines: 3
    instructions: Keep the decision, owner and deadline.

  - name: A particular person's messages
    match: { app: slack, person: "Example Person" }
    profile: esl
    max_lines: 5

  - name: This recurring thread
    match: { app: slack, thread: "Website release checklist" }
    instructions: Keep unresolved blockers and distinguish suggestions from decisions.
```

`app`, `channel`, `title` (regex), `text` (regex) and `mode` are matched locally.
`person`, `sender_domain` and `thread` are matched by Claude from the screenshot.
These are best-effort visual matches; if the identity is unclear, the rule is
skipped. Rules run in file order and later line limits win. `max_lines` is an
instruction to the model, not a hard limit. Allowed limits are 1 to 30.

### Notes and Google Drive context

Plainspeak ships read-only `vault_search` and `vault_note` tools for a local
Obsidian vault. Point `~/.plainspeak/config.json` at your vault and restart
Plainspeak. Search covers up to 4,000 notes and the first 16,000 characters of each.
Reads outside the vault, including through symlinks, are refused. There is no
write tool.

Google Drive works through the Drive connector your Claude account already has.
To reach it, a context lookup loads your Claude settings, but it can only run the
read-only Obsidian and Drive tools. A hook blocks everything else, even tools your
own settings allow. There are no approval prompts. Without a connected source,
the panel says context was not checked.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| Buttons do nothing, or "Plainspeak unavailable" | Plainspeak is not running. Run `bun run start`. |
| "Port 8790 is already in use" | The old tmux daemon is running. Run `bun run daemon:stop`, then `bun run start`. |
| "Claude could not finish this capture: Not logged in" | Run `claude` in a terminal, sign in, then restart Plainspeak. |
| "Claude did not respond within two minutes" | Usually a usage limit. Check the terminal or `~/.plainspeak/launchd.log`. |
| "Unauthorised" | Hammerspoon is reading an old token. Run `bun run install:hammerspoon` again. |
| "Accessibility" or "Screen Recording is not active" | Grant the permission, then quit and reopen Hammerspoon. |
| Buttons swapped or not detected | PS menu > **Set front mouse button…**, press it, then the same for the back button. |
| Draft hotkey says to select text | The app does not expose its selection to macOS. Copy the text into another editor. |

## Privacy and safety

- Screenshots and selected text go to Claude through your signed-in account. Do
  not capture anything you cannot share with the provider.
- The service binds to `127.0.0.1` and checks the token, Host and Origin headers,
  so web pages cannot post captures.
- Captures are never written to logs. Temporary screenshots are deleted after a
  result, a timeout or a clean shutdown; a crash can leave one in `~/.plainspeak`.
- Results stay in memory for ten minutes. Claude sessions are not saved to disk.
- There is no sending endpoint. Normal reads run with no tools; context lookups
  can only read Obsidian and Google Drive.
- Nothing runs in the background: no polling, no unread-message scraping, no
  automatic screenshots.
- A rewrite can misread a message. Check dates, numbers and commitments before
  you act on them.

## Limits

- macOS only, Claude only.
- Usage counts against your plan's limits. The session is replaced every 15
  captures to keep each capture small. Context lookups use more.
- Identity-based rules depend on what Claude can see in the screenshot.
- Automatic thread lookup from a tab title is not implemented.

## Develop

```sh
bun test
bun run typecheck
```

The tests cover rule matching, capture authentication, foreign-origin rejection,
request and result correlation, concurrent captures, screenshot lifetime,
transport failure, invalid configuration, vault path boundaries, and the engine's
warm-up, streaming, session renewal, failures and read-only context tools. They
use a stand-in Claude session, so they do not spend model usage.

References: [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview),
[Claude channels](https://code.claude.com/docs/en/channels),
[channels reference](https://code.claude.com/docs/en/channels-reference),
[Hammerspoon window snapshot](https://www.hammerspoon.org/docs/hs.window.html#snapshot),
[Hammerspoon webview](https://www.hammerspoon.org/docs/hs.webview.html).

## Licence

[MIT](LICENSE). Illustrations in `docs/images` use fictional messages.
