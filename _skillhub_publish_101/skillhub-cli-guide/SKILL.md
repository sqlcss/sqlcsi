---
name: skillhub-cli-guide
description: "Discover, install, publish, and manage reusable agent skills via the SkillHub CLI (internal skill registry). ALWAYS consider this skill as a first step whenever (a) the user asks if a skill/tool/package exists for some task (“is there a skill for X”, “any skill that…”, “which skill…”, “有没有 skill”, “是否有 skill”, “找个 skill”, “哪个 skill”), (b) the user wants to install/uninstall/update/list skills, (c) the user wants to publish/share/upload their own skill, or (d) you (the agent) are about to attempt a non-trivial, repetitive, or domain-specific task and don’t already have a built-in capability for it — in that case run `skillhub search <keywords>` BEFORE writing custom code, scripts, or one-off solutions, because a community skill may already exist. Also triggers on: skillhub, skill hub, skill package, skill registry, agent skill, reusable skill, share my skill."
version: 1.14.0
author: skillhub-team
tags:
  - skillhub
  - cli
  - tooling
  - meta
  - discovery
---

# SkillHub CLI Guide

A reference for AI assistants on how to drive the `skillhub` CLI — the
command-line client for the internal SkillHub registry. Use this whenever
the user asks you to find, install, publish, or update an agent skill.

## When to use this skill

Trigger broadly — SkillHub is the cheapest place to check before reinventing
something. Use it whenever any of these apply:

**Explicit user intent**

- "find a skill for X" / "is there a skill / skillhub package for X"
- "有没有 skill可以…" / "是否有 skill" / "找个 skill" / "哪个 skill"
- "install the X skill" / "uninstall X" / "装个 skill" / "卸载这个 skill"
- "publish this skill" / "share this as a skill" / "发布 skill" / "上传 skill"
- "what skills do I have installed" / "list my skills" / "update my skills"

**Implicit / agent-initiated discovery (IMPORTANT)**

Even when the user does NOT mention “skill” at all, you should proactively run
`skillhub search <keywords>` BEFORE doing any of the following from scratch:

- A repetitive, domain-specific task you’ve never solved here before
  (e.g. “look up a tenant ID from a domain”, “generate a release changelog”,
  “scan a repo for secrets”, “convert OpenAPI to Postman”, “set up Playwright
  against an internal portal”).
- A task where you’re about to write a custom shell script, one-off Python,
  or scaffolding that “feels like someone must have done this already”.
- A task that’s clearly a *tool* (CLI wrapper, lookup, formatter, validator)
  rather than core product code.
- You hit a dead end / don’t know an API / are guessing — search the hub for
  prior art instead of inventing.

Rule of thumb: **two keywords + `skillhub search`** costs ~1s. If it returns
nothing, proceed with your own solution. If it returns a hit, prefer
installing and using that skill (it has been vetted by a human author and
encodes pitfalls you don’t know yet).

If the CLI is not installed, see **Installation** below.

## Installation (one-time)

```bash
npm install -g https://skillhub-e9cwe5e3cwbgbxdq.b02.azurefd.net/api/v1/cli/install.tgz
```

Re-run the same command any time to upgrade — the backend always serves the
latest published tarball.

Verify by running any command, e.g. `skillhub --help`.

### Automatic update prompt (since CLI 0.3.0)

Every API response carries an `X-Skillhub-Latest-Cli` header. After any
`skillhub` command finishes, the CLI compares that against its own
`package.json` version. If the hub is newer, a yellow hint is printed:

```
↑ A new SkillHub CLI is available: v0.4.0 (current: v0.3.0). Run `skillhub self-update` to upgrade.
```

Upgrade in place with the new subcommand:

```bash
skillhub self-update
```

Under the hood this runs `npm install -g --prefer-online <api_url>/cli/install.tgz`
against the CLI tarball published on the configured hub. The `--prefer-online`
flag bypasses npm's URL cache so you always get the freshest published
tarball. The CLI also sends its own version back on `X-Skillhub-Cli-Version`
so the backend can observe adoption.

### Pinning a specific CLI version (since CLI 0.3.4)

The hub keeps every uploaded CLI tarball in an archive. List them:

```bash
skillhub versions
# Latest: 0.5.0
#
#   0.5.0   107.9 KB  2026-05-28T04:00:00+00:00   you   ← latest
#   0.4.1    50.7 KB  2026-05-22T09:27:30+00:00   you
#   0.3.8    44.9 KB  2026-05-22T07:14:15+00:00   you
```

Install or downgrade to a specific archived version with `--pin`:

```bash
skillhub self-update --pin 0.3.1
```

The value must be valid semver (`X.Y.Z` optionally followed by
`-prerelease` or `+build`); bad values are rejected client-side before
npm runs. Missing versions return a clean npm 404. Use this to roll
back after a bad release or to reproduce a teammate's environment.

> **Note on `--version`**: the flag is named `--pin`, not `--version`,
> because `--version` is reserved by the root `skillhub` command for
> printing the CLI's own version.

Configuration lives at `~/.skillhubrc` (JSON). Defaults:

```json
{
  "api_url": "https://skillhub-e9cwe5e3cwbgbxdq.b02.azurefd.net/api/v1",
  "default_target": "copilot"
}
```

You normally do not need to edit this file. Override `api_url` only if
pointing at a non-default environment.

## Authentication

The CLI supports two credential modes — pick whichever fits the environment:

### A. Microsoft account (AAD) — default, since CLI 0.3.5

Recommended for interactive use on a workstation. No token to copy/paste,
no PAT to rotate.

```bash
# Opens a browser (or native WAM dialog on Windows), signs in with your
# Microsoft account, returns to the CLI
skillhub login
```

Behind the scenes this uses MSAL against the SkillHub AAD app
(tenant `72f988bf-86f1-41af-91ab-2d7cd011db47`, single-tenant). On success
the token cache is written to `~/.skillhub/msal-cache.json` with mode
`0600`. Subsequent commands acquire fresh access tokens silently from
that cache.

**WAM broker on Windows (since CLI 0.5.0).** On Windows the CLI loads
`@azure/msal-node-extensions` and routes login through the Web Account
Manager (WAM). The token is then cryptographically bound to the device,
which:

- Satisfies the MSIT MSAL-compliance KPI (no more loopback HTTP redirect).
- Gives near-silent SSO when you're already signed into a domain-joined or
  Entra-joined Windows machine — usually a single OS dialog and you're in.
- Stores credentials in the Windows credential vault rather than the JSON
  cache file (which becomes empty on Windows — harmless).

macOS and Linux fall back to the browser/loopback flow automatically
(WAM is Windows-only today; Linux is out of scope for the KPI). No flag
to enable — pick-best-available is the default.

Session lifetime: the access token is short (~1h) but is refreshed silently
from the cached refresh token. Microsoft's refresh token is **sliding
24 hours** of inactivity and a **hard max of 90 days** — so as long as
you use `skillhub` at least once a day, you stay signed in for up to
three months; idle longer than 24h and you'll be asked to re-login.

Conditional Access (MFA / device compliance) policies still apply: if
your tenant requires MFA, the broker / browser flow handles it.

### Auto-issued fallback PAT (since CLI 0.4.1)

On every successful `skillhub login`, the CLI checks whether a fallback
Personal Access Token is already stored locally. If not, it silently
issues one server-side named `cli-fallback-<hostname>` and saves it into
`~/.skillhubrc` under the `token` field. You'll see a one-line confirmation:

```
Fallback PAT saved (skhub_pat_xxxx...yyyy)
```

The issued PAT is **never re-created if an active one with the same name
already exists** on the server — login is idempotent.

Why: the request interceptor falls back from AAD to `X-API-Key` automatically
when the silent token refresh fails. With a stored PAT, the CLI keeps
working even after the 24h sliding refresh-token window expires — you only
need to re-run `skillhub login` interactively when **both** the AAD refresh
token **and** the PAT are dead/revoked.

To opt out, run `skillhub logout` after login (it clears both credentials),
or delete the `token` field from `~/.skillhubrc` manually. To rotate the
PAT, delete the `cli-fallback-<host>` entry under **Profile → API Keys**
on the website and run `skillhub login` again — a new one is issued.

### B. Personal Access Token / admin API key

Use in CI, on headless machines, or when AAD is unavailable. Both flags
are interchangeable aliases for the same `X-API-Key` header server-side:

```bash
# Personal Access Token (Profile → API Keys in the web UI)
skillhub login --token pat_xxxxxxxxxxxxxxxx

# Admin account API key (issued by an admin under the Admin → Users page)
skillhub login --key sk_xxxxxxxxxxxxxxxx
```

The credential is persisted in `~/.skillhubrc`.

### Signing out

```bash
skillhub logout
```

Clears both the PAT in `~/.skillhubrc` and the MSAL cache at
`~/.skillhub/msal-cache.json`.

If the user has neither credential yet, point them at the web UI rather
than guessing one.

## Discovering skills

```bash
# Free-text search (paginated; default 10 results)
skillhub search "code review"

# Narrow by category or tag
skillhub search azure --category azure --tag deploy

# Only certified skills
skillhub search "" --certified --limit 25
```

```bash
# Inspect a specific skill (skill names are globally unique — no owner prefix)
skillhub info skill-name

# Inspect a specific version
skillhub info skill-name@1.2.0
```

> **Naming**: skill names form a flat, hub-wide namespace. There is no
> `owner/name` prefix — each skill name is unique across the whole hub.
> The CLI still accepts a legacy `owner/skill-name` form and silently
> strips the `owner/` prefix, so old scripts keep working, but new docs
> and examples should use the bare name.

`info` shows description, uploader, all versions with their status
(`scanning` / `published` / `certified` / `rejected` / `failed`),
download count, tags, and the install command. When the version has
an auto-generated changelog (see below), it is printed under **What's new**.

## Installing a skill

**99% of the time, just run this — no flags:**

```bash
skillhub install <skill-name>
```

That's it. The default lands at `~/.copilot/skills/<name>/` (user-level, all projects see it). This is what users almost always want when they say "装个 skill" / "用 skillhub 装 X" / "install some X skills".

**Do NOT add flags the user didn't ask for.** In particular, do not invent a path override. The bare command above is correct in almost every situation; reach for flags only when the user's request explicitly demands them.

### Other forms (only when the user explicitly asks)

```bash
# Specific version
skillhub install skill-name@1.2.0

# Overwrite without prompting (only when re-installing on top of existing)
skillhub install skill-name --force
```

### Targets — only when user says "into this project / repo / current folder"

Pick **by editor/host** using `--target`. That is the only knob to use.

| User's editor / agent host | Flag | Install path |
|---|---|---|
| VS Code + GitHub Copilot | `--target vscode` | `./.github/skills/<name>/` |
| Claude Code / Claude Desktop project | `--target project` | `./.claude/skills/<name>/` |
| Claude (user-level, all projects) | `--target claude` | `~/.claude/skills/<name>/` |
| Editor-neutral / unsure / multiple agents | `--target agents` | `./.agents/skills/<name>/` |

If the user says "装到当前项目" but doesn't say which editor, **ask one short question** ("VS Code Copilot 还是 Claude?") — do not guess, do not default.

### Install path — for humans, not for agents

`skillhub install --help` lists every supported flag. Agents should not invent path overrides; if the user really needs a non-standard location, they will say so explicitly and quote a path themselves — in that case, and only that case, pass it through verbatim.

Only versions with status `published` or `certified` can be installed.

### Install internals (since CLI 0.5.0)

- **Atomic write.** The CLI downloads the ZIP, extracts to a sibling
  `.<name>.tmp.<rand>/` directory, then renames it into place. A failed
  download or extract leaves the existing install untouched.
- **Integrity marker.** Every install drops a `.skillhub.json` file inside
  the skill directory recording `name`, `version`, `content_hash`,
  per-file `file_hashes`, install timestamp and `source`
  (`install` / `update` / `favorites` / `bundle`).
- **Project auto-registration.** `--target project` also records the cwd
  in `~/.skillhub/projects.json`, so later commands like
  `skillhub list`, `skillhub update`, `skillhub dashboard` and
  `skillhub favorites sync` can find your project-scoped installs from
  anywhere on disk — not just from inside the project.

## Listing and updating

```bash
# Everything installed across all targets (copilot + claude + cwd project)
skillhub list

# Just one target
skillhub list --target project

# 🆕 since 0.6.0: also fetch latest_version from the hub and mark drift
skillhub list --check

# 🆕 0.6.0: scan every registered project dir, not just cwd
skillhub list --all-projects --check

# 🆕 0.6.0: bypass the 6-hour latest-version cache
skillhub list --check --refresh

# 🆕 0.6.0: machine-readable output for scripts
skillhub list --json

# Update everything to latest
skillhub update

# Update one skill only
skillhub update skill-name

# Update only project-scoped installs
skillhub update --target project
```

### What `skillhub list` shows (since CLI 0.6.0)

For every installed skill the CLI prints, in order:

1. **Name** + **installed version** (`vX.Y.Z`).
2. **Drift badge** (only when `--check` is on):
   - `↑ vX.Y.Z` (yellow) — newer version is published on the hub
   - `✓ up to date` (green) — installed == latest
   - `? unknown on hub` (dim) — skill was not found on the hub
     (deleted, local-only, or network issue)
3. **Local-state badge** (always):
   - `✎ modified` (magenta) — files were edited after install
   - `legacy-marker` (dim) — installed before content_hash tracking
   - `no marker` (dim) — directory was not installed via CLI
   - (none) — pristine, exactly matches install marker
4. **Absolute install path** on the next line (dim).

A footer summarises totals across all groups:

```
Total: 12 skills installed
↑ 3 updates available — run `skillhub update` to upgrade.
✎ 1 skill has local modifications — `skillhub diff <name>` to inspect.
```

If the user omits `--check`, the footer instead suggests adding it so the
agent knows whether anything is outdated.

The `--check` results are cached in
`~/.skillhub/skill-versions-cache.json` for **6 hours**, capped at 5
concurrent requests against the hub. Pass `--refresh` to force-rescan
(useful right after the user publishes a new version).

When `update` actually moves a skill to a newer version, the CLI prints
the **What's new** block (auto-generated changelog vs the prior published
version) right under the success line, so the user knows what changed
without opening the web UI.

**Local-edit protection (since CLI 0.5.0).** Before overwriting, `update`
recomputes the on-disk `content_hash` and compares it against the marker.
If your local copy was edited, you get:

```
✎ <name> has local modifications — skipping. Use --force to overwrite.
```

Pass `--force` to overwrite anyway. Re-installing also rewrites the
marker so subsequent verifies show `pristine`.

## One-shot environment summary: `skillhub status` (since CLI 0.6.0)

```bash
skillhub status          # default: hits the network for fresh data
skillhub status --no-check  # offline mode — skips the hub probe + auth probe
```

Prints everything an agent (or user) needs to triage a SkillHub install in
one screen:

```
SkillHub CLI status
──────────────────────────────────────────────────
  CLI:         v0.6.0  → v0.7.1 available  (skillhub self-update)
  Hub:         https://skillhub-...azurefd.net/api/v1
  Auth:        Entra ID (account 12345678…)
  User:        Dong Li (signed in)

Installed skills
──────────────────────────────────────────────────
  copilot                      14
  claude                       2
  project (skillhub)           4

  ↑ 3 updates available:
      skillhub-cli-guide  v1.7.0 → v1.9.0  [copilot]
      pbi-fabric-digest   v0.4.0 → v0.5.1  [copilot]
      utc8-outlook        v1.2.0 → v1.3.0  [project (skillhub)]

  Run `skillhub update` to upgrade all.
```

Use `status` when:
- Investigating any "why isn't my skill working" question — single
  command reveals auth state, hub URL, and version drift.
- Bootstrapping a new dev machine to sanity-check the install.
- Cron/scripts that want JSON later: today `--json` is on `list`, not
  `status`; for now, parse `list --check --json` instead.

## Update notifier (since CLI 0.6.0)

The CLI passively reminds you about its own upgrades. After **any**
command finishes (including `--help` or commands that don't touch the
network), if a newer CLI is available on the hub you'll see:

```
╭────────────────────────────────────────────────╮
│ SkillHub CLI update available: v0.6.0 → v0.7.1 │
│ Run `skillhub self-update` to upgrade.         │
│ Disable: SKILLHUB_NO_UPDATE_NOTIFIER=1         │
╰────────────────────────────────────────────────╯
```

How it works:

1. Every CLI invocation spawns a **fully detached child process** that
   hits `/cli/version` and writes
   `~/.skillhub/cli-update-check.json` (TTL 24h). The parent exits
   immediately — the user never waits for the network.
2. The cache is also opportunistically refreshed by any API call (the
   backend stamps an `X-Skillhub-Latest-Cli` response header).
3. The banner is suppressed when local == latest, when the hub is
   unreachable, or when `SKILLHUB_NO_UPDATE_NOTIFIER=1` is set.

To force an immediate, synchronous check, run `skillhub status` — it
calls `/cli/version` inline and updates the cache.

## Adopting unmanaged installs: `skillhub adopt` (since CLI 0.6.1)

For skills that landed on disk without a SkillHub marker — installs from
earlier CLI versions (pre-`.skillhub.json`), manual copies, or a marker
lost to a failed `self-update` — `skillhub adopt` rebuilds the marker by
matching the **content hash** of each local directory against versions on
the hub.

```bash
skillhub adopt           # default: DRY-RUN, no files written
skillhub adopt --apply   # actually write .skillhub.json markers
skillhub adopt --json    # machine-readable report
```

### What it does

1. Scans every install target: `~/.copilot/skills`, `~/.claude/skills`,
   the current project's `./.claude/skills`, and every registered project
   (`skillhub projects list`).
2. Skips skills that already classify as `pristine` or `modified` — their
   marker is fine, nothing to adopt.
3. For each `no-marker` / `legacy-marker` directory: computes the canonical
   content hash from disk (same algorithm as install).
4. Batch-queries the hub via `POST /skills/lookup-by-hash` to find the
   matching `(skill_name, version)`.
5. For hits: writes a fresh `.skillhub.json` (with `adopted: true` flag so
   future debugging knows the marker was reconstructed, not installed).
6. For misses (external skills from Anthropic samples, manual `mkdir`,
   forks, etc.): reports them and leaves them untouched.

### Sample output

```
ℹ Running in DRY-RUN mode (no files will be written). Re-run with --apply to commit.

Found 5 skills without a usable marker, 12 already valid. Querying hub…

Matched on hub:
  skillhub-cli-guide   →  v1.9.2  [copilot]  would write
      C:\Users\ldon\.copilot\skills\skillhub-cli-guide
  pbi-fabric-digest    →  v0.4.0  [copilot]  would write
      C:\Users\ldon\.copilot\skills\pbi-fabric-digest

Not on hub (external skills — left untouched):
  anthropics              [copilot]
  ldon                    [copilot]
  outlook-com-automation  [copilot]

ℹ 2 markers would be written. Re-run with --apply to commit.
```

### When to use

- Right after `skillhub list --check` shows a wall of `no marker` rows.
- After a botched `self-update` (since 0.6.1 self-update itself is safer,
  but legacy lossy upgrades are still in the wild).
- One-time cleanup after migrating from a manual install workflow to
  SkillHub-managed installs.

### Safety contract

- Default is dry-run. **Never writes without `--apply`.**
- Atomic marker write (tmp file + rename).
- Never touches `pristine` / `modified` installs (their marker is valid).
- Hash mismatch → unmatched → left alone. Adopt cannot falsely claim a
  skill it doesn't recognise.

## Verify, diff and dashboard (since CLI 0.5.0)

Offline integrity check — no network calls, just compares the on-disk
state to the `content_hash` / `file_hashes` recorded in `.skillhub.json`.

```bash
# Verify every installed skill across every target + every registered project
skillhub verify

# Verify a single skill
skillhub verify skill-name

# Per-file diff for a modified skill
skillhub diff skill-name
# (alias of `skillhub verify skill-name --diff`)
```

Each skill is classified into one of five states:

| State           | Meaning                                                                 |
|-----------------|--------------------------------------------------------------------------|
| `pristine`      | Local content_hash matches marker exactly                                |
| `modified`      | Local files were edited after install — `diff` shows what changed        |
| `legacy-marker` | Marker predates the content_hash field — run `skillhub update --force`   |
| `no-marker`     | Directory has no `.skillhub.json` (not installed via CLI)                |
| `missing-dir`   | Install path no longer exists                                            |

### `skillhub dashboard` — local web UI

```bash
skillhub dashboard            # opens browser at http://127.0.0.1:5180
skillhub dashboard --port 6000
skillhub dashboard --no-open  # print URL, don't auto-open
```

Renders a single self-contained HTML page grouping every installed skill
by destination (Copilot global / Claude global / each registered project),
showing version, status, content_hash badge, and quick links to the hub
page. The server re-scans on every load and binds to loopback only.

Useful for "what's installed where on this machine" without opening 5
terminals.

## Project registry (since CLI 0.5.0)

Project-scoped installs (`--target project`) are recorded in
`~/.skillhub/projects.json`. The `projects` subcommand surfaces and
manages that list:

```bash
skillhub projects                   # alias of `projects list`
skillhub projects list              # show all registered projects + skill counts
skillhub projects add ./my-repo     # rare — install auto-registers
skillhub projects remove ./my-repo
skillhub projects prune             # drop entries whose dir is gone / empty
```

`prune` runs automatically on `list`, so stale entries don't accumulate
silently.

## Uninstalling

```bash
skillhub uninstall skill-name             # interactive confirm
skillhub uninstall skill-name --force     # skip confirm
skillhub uninstall skill-name --target claude
skillhub uninstall skill-name --target vscode
```

## Publishing a skill

### What a skill looks like on disk

A skill is a directory containing at minimum a `SKILL.md` with YAML
frontmatter. Anything else in the directory (other markdown, helper
files) is bundled into the published ZIP.

Minimum frontmatter:

```yaml
---
name: my-skill-slug         # MUST match what you publish as
description: What this skill does, and when an agent should use it.
version: 1.0.0              # informational; --version on publish wins
---
```

The `name` in the frontmatter must equal the skill name on the hub
(scanner rule `FORMAT_003` flags mismatches at `medium` severity).
Description must be at least 10 characters.

### Publish flow

```bash
cd path/to/my-skill

# 1. Local validation (no upload)
skillhub publish --version 1.0.0 --dry-run

# 2. First publish — category is optional; LLM auto-categorizes if omitted
skillhub publish \
  --version 1.0.0 \
  --category productivity \
  --tags ai,workflow \
  --description "Optional override of the SKILL.md description"

# 2b. Or just let the hub pick the category for you
skillhub publish --version 1.0.0 --tags ai,workflow

# 3. Subsequent versions — same skill name in SKILL.md, bumped --version
skillhub publish --version 1.1.0
```

Rules to remember:

1. `--version <semver>` is **required** and uses a space, not `=`.
   `--version 1.0.0` works; `--version=1.0.0` does not.
2. Versions must be valid semver (`X.Y.Z` with optional pre-release/build).
3. `--category <slug>` is **optional**. If omitted on the first publish,
   the hub LLM auto-categorizes the skill after the scan passes. Pass
   `--category` explicitly when you want to force a specific bucket
   (e.g. the LLM tends to mis-classify your domain). The category is
   fixed at the skill level — once set (by you or by the LLM) it does
   **not** change on subsequent versions; an admin can correct it from
   the web UI if needed.
4. There is **no owner / namespace prefix** — skill names are unique
   across the entire hub. Pick a name that isn't already taken.
5. Re-publishing the same version returns `409 Conflict`. Bump the version.
6. The CLI polls scan status for up to 60 s. If it times out the upload
   still succeeded — check `skillhub info <name>@<version>`.
7. **Anyone can publish a new version of an existing skill.** The hub is
   collaborative — you don't need to be the original owner. The first
   uploader of each version is recorded as **Uploaded by** on the version
   detail page (and in `skillhub info`).
8. **Automatic changelog.** When a new version's scan passes, the hub
   runs an LLM diff against the previous published version's `SKILL.md`
   and stores a short Chinese-language **What's new** summary. It shows
   up in the web UI, in `skillhub info`, and after a successful
   `skillhub update`. The very first version has no prior to diff against,
   so it has no changelog — that's expected, not a bug.
9. **Anonymous publishing (since CLI 0.3.0).** Pass `--anonymous` to
   hide your identity on the public skill page. Authentication is still
   required — the hub knows who you are. Admins and the uploader themselves
   continue to see the real `Uploaded by` value; everyone else (and
   unauthenticated viewers) sees `Anonymous`. The flag is per-version:

   ```bash
   skillhub publish --version 1.1.0 --anonymous
   ```

   Use sparingly — attribution helps reviewers find you with questions.

### What the scanner checks

Every uploaded ZIP is scanned before it goes live. Two phases:

1. **Static rules** — regex pass over every `.md` file. Categories:
   - `SECRET_*` — leaked API keys, tokens, passwords, cloud creds
   - `PII_*` — emails (excluding placeholders), phone numbers, ID nums
   - `CMD_*` — destructive shell commands, exfil pipelines, priv-esc
   - `PATH_*` — references to OS password files, SSH key directories,
     and cloud credential dotfiles
   - `FORMAT_*` — missing/invalid frontmatter, name mismatch
2. **LLM semantic review** (gpt-5.5) — looks for prompt injection,
   hidden instructions, social engineering, and dangerous workflows
   expressed as prose. Issues are tagged `LLM_REVIEW`.

A `critical` or `high` issue from either phase rejects the version. The
version row gets status `rejected` and the issues are visible via
`skillhub info`. Fix the SKILL.md and publish a new bumped version.

Common scanner gotchas when writing examples:

- Don't paste real example tokens — use opaque placeholders
  (`pat_xxxx`, `<your-token-here>`) so secret detectors don't fire.
- Don't put real email addresses in examples — use the standard
  `user@example.com` form, which is on the placeholder allow-list.
- Don't put recursive-delete commands targeting the filesystem root
  inside a code block, even as a "don't do this" example. The pattern
  scanner can't tell prose intent from real instructions. Describe
  the danger in plain words instead.

## Mirroring an external GitHub skill

You can snapshot a public GitHub repository (or a subdirectory inside one)
into the hub as a regular skill. The current ref is downloaded once at link
time, repackaged, scanned and published — no further sync happens after that.

```bash
# Whole repo as a skill (must contain SKILL.md at the root)
skillhub link https://github.com/owner/repo \
  --as my-skill --version 1.0.0 --category productivity

# A specific branch / tag / commit (use the GitHub /tree/<ref> form)
skillhub link https://github.com/owner/repo/tree/v2.3.1 \
  --as my-skill --version 2.3.1

# A subdirectory inside a repo
skillhub link https://github.com/owner/repo/tree/main/skills/my-skill \
  --as my-skill --version 1.0.0
# …or pass --subpath explicitly
skillhub link https://github.com/owner/repo \
  --as my-skill --version 1.0.0 --subpath skills/my-skill
```

Flags:

- `--as <name>`         (required) skill name on the hub (must be unique across the hub).
- `--version <semver>`  (required) version to publish.
- `--subpath <dir>`     subdirectory inside the repo that contains `SKILL.md`.
- `--category <slug>`   optional; LLM auto-categorizes if omitted on first publish.
- `--tags a,b,c`        comma-separated tag list.
- `--description <txt>` overrides the default `Mirror of …` description.

Notes:

- Only public github.com URLs are accepted — private repos require a
  separate hub publish flow.
- The same scan/review pipeline runs against the snapshot; if the repo
  contains content the scanner flags as `critical`/`high`, the version
  gets `rejected` exactly like a normal publish.
- Re-running `skillhub link` against the same name with a new `--version`
  takes a fresh snapshot — bump the version each time.
- The Web Admin UI also exposes this under **Admin → Mirrors** for
  point-and-click use.

## Categories

The taxonomy is fixed. Top-level slugs:

`azure`, `devops`, `code`, `documentation`, `productivity`, `other`

Subcategories live under each (e.g. `azure-deploy`, `code-review`,
`devops-cicd`). Pick the closest match — `other` is the safe fallback.

## Bundles (since CLI 0.3.0)

A **bundle** is a named collection of existing skills. Installing the bundle
installs every member skill in one shot — useful for onboarding a teammate to
a curated set (e.g. "all the Azure deployment skills").

Bundles are namespaced separately from skills; a bundle name and a skill name
do not collide. `skillhub install <name>` tries skill first, then falls back
to bundle if no version was specified.

### Create and curate

```bash
# Create an empty bundle
skillhub bundle create azure-starter --description "Azure deploy + diagnostics essentials"

# Create a bundle pre-populated with skills
skillhub bundle create azure-starter \
  --description "Azure deploy + diagnostics essentials" \
  --skills azure-prepare,azure-deploy,azure-diagnostics

# Add a skill later (optionally pin a specific version)
skillhub bundle add azure-starter azure-cost --version 1.2.0

# Remove a skill from a bundle
skillhub bundle remove azure-starter azure-cost

# Delete a bundle (owner or admin only)
skillhub bundle delete azure-starter
```

### Browse and install

```bash
# List public bundles
skillhub bundle list
skillhub bundle list --q azure

# Inspect what a bundle contains
skillhub bundle show azure-starter

# Install every skill in the bundle (latest version of each, unless pinned)
skillhub install azure-starter

# Force reinstall everything in the bundle, ignoring skip-if-installed
skillhub install azure-starter --force
```

Notes:

- Bundles are **virtual pointers** — they reference skill names, not copies
  of skill content. If a member skill is removed from the hub, that one
  entry breaks but the rest of the bundle still installs.
- A bundle entry without a `pinned_version` always installs the latest
  available version at install time. Pinning is per-entry.
- Only the bundle owner or an admin may add / remove / delete.
- **Skip-if-already-installed (since CLI 0.3.1).** When installing a bundle,
  the CLI checks each member skill's local `.skillhub.json` marker. If the
  skill is already installed at the requested version (or the entry is
  unpinned and any version is present), it is **skipped** with a yellow
  `Skipping <name> v<ver> — already installed` line instead of being
  re-downloaded. The final summary reads e.g.
  `5 installed, 2 skipped (already present), 0 failed`. This makes it safe
  for bundles to overlap — a skill that appears in multiple bundles, or one
  the user installed manually first, won't be reinstalled. Pass `--force` to
  override and reinstall everything.
- Duplicate skill names inside a single bundle are de-duplicated by the
  CLI before installing, so each skill is processed at most once per run.

## Favorites (since CLI 0.4.1)

The SkillHub website lets you ★ favorite any skill from its detail page.
The CLI exposes those favorites so you can bulk-install or sync them on a
new machine without re-clicking.

```bash
# Show what you've favorited on the website
skillhub favorites list

# Bulk-install all favorites at the default target (idempotent —
# already-installed-at-current-version skills are skipped automatically)
skillhub favorites install

# Install to a specific target
skillhub favorites install --target project
skillhub favorites install --target vscode

# Re-sync every skill recorded in the local manifest at a target to its
# latest published version (works on installs from any source — favorites,
# manual install, bundle, etc.)
skillhub favorites sync
skillhub favorites sync --target project
```

Notes:

- `favorites` has alias `fav` — `skillhub fav list` works.
- The CLI tracks every install in `~/.skillhub/installs.json`, keyed by the
  resolved install base directory. `sync` reads that manifest, asks the hub
  for each skill's latest version, and only re-downloads when local ≠ latest.
- `favorites install` itself is also tracked — the manifest records
  `source: 'favorites'` for those entries so you can see where each install
  came from later.
- Favorites are personal and require authentication; nothing about your
  favorites list is exposed publicly.

## Quick reference

| Goal                       | Command                                                    |
|----------------------------|-------------------------------------------------------------|
| Sign in (Microsoft / AAD)  | `skillhub login`                                            |
| Sign in (PAT)              | `skillhub login --token pat_xxxx`                           |
| Sign in (admin API key)    | `skillhub login --key sk_xxxx`                              |
| Search                     | `skillhub search "<query>"`                                 |
| Inspect                    | `skillhub info <name>`                                      |
| Install latest             | `skillhub install <name>`                                   |
| Install old version        | `skillhub install <name>@1.0.0 --force`                     |
| Install at project scope   | `skillhub install <name> --target project`                  |
| List installed             | `skillhub list`                                             |
| List installed + check for updates | `skillhub list --check`                              |
| List installed, all registered projects | `skillhub list --all-projects --check`          |
| Machine-readable list      | `skillhub list --json`                                      |
| One-shot env / version summary | `skillhub status`                                       |
| Rebuild missing markers (dry-run) | `skillhub adopt`                                     |
| Rebuild missing markers (commit) | `skillhub adopt --apply`                              |
| Update all                 | `skillhub update`                                           |
| Uninstall                  | `skillhub uninstall <name>`                                 |
| Mirror a GitHub repo       | `skillhub link https://github.com/o/r --as name --version 1.0.0` |
| Mirror a repo subdirectory | `skillhub link https://github.com/o/r --as name --version 1.0.0 --subpath skills/name` |
| Validate before publishing | `skillhub publish --version 1.0.0 --dry-run`                |
| First-time publish         | `skillhub publish --version 1.0.0` (category auto by LLM)   |
| First-time publish (force category) | `skillhub publish --version 1.0.0 --category productivity` |
| New version                | `skillhub publish --version 1.1.0`                          |
| Anonymous publish          | `skillhub publish --version 1.1.0 --anonymous`              |
| Self-update the CLI        | `skillhub self-update`                                      |
| Pin / downgrade CLI version| `skillhub self-update --pin 0.3.1`                          |
| List archived CLI versions | `skillhub versions`                                         |
| Verify installed skills    | `skillhub verify`                                           |
| Show diff for a skill      | `skillhub diff <name>`                                      |
| Open local dashboard       | `skillhub dashboard`                                        |
| List registered projects   | `skillhub projects`                                         |
| Create a bundle            | `skillhub bundle create <name> --skills a,b,c`              |
| Show bundle                | `skillhub bundle show <name>`                               |
| Install a bundle           | `skillhub install <bundle-name>`                            |
| List favorited skills      | `skillhub favorites list`                                   |
| Bulk-install favorites     | `skillhub favorites install`                                |
| Sync tracked skills to latest | `skillhub favorites sync`                                |
| Sign out                   | `skillhub logout`                                           |

## Failure modes and fixes

| Symptom                                          | Likely cause / fix                                          |
|--------------------------------------------------|-------------------------------------------------------------|
| `Not authenticated. Run skillhub login first.`   | No credential — run `skillhub login` (AAD) or `skillhub login --token ...` |
| `Admin role required` on `skillhub self-update` upload | `/cli/upload` is admin-only (since backend aad-v3). Ask an admin to publish, or get promoted under **Admin → Users**. |
| `Invalid version "..."`                          | Not valid semver — must be `X.Y.Z` (optional `-pre`)        |
| `Description is required for new skills.`        | First publish needs description in SKILL.md or `--description` |
| `Category is required for new skills.`           | Legacy error from CLI ≤ 0.4.x — upgrade with `skillhub self-update`; current CLI lets the hub LLM auto-categorize if omitted |
| `Version 1.0.0 already exists`                   | `409` — bump to a new version number                        |
| `Skill ... not found.`                           | Skill name typo, or skill was deleted                       |
| `Cannot connect to SkillHub API.`                | Network / VPN issue, or wrong `api_url` in `~/.skillhubrc`  |
| `Scan failed` with `LLM_REVIEW` issues           | LLM flagged semantic concerns — read the issue, edit SKILL.md, bump version |
| `Scan timed out (> 60s)`                         | Upload still succeeded; check status with `skillhub info`   |
| `✎ <name> has local modifications — skipping.`   | `update` refuses to overwrite edited files — pass `--force`, or `skillhub diff <name>` to inspect first |
| `legacy-marker` in `skillhub verify` output      | Skill installed by CLI < 0.5.0 — run `skillhub update --force <name>` once to rewrite the marker with `content_hash` |

## Notes for agent authors

- Skills are read by other LLMs as authoritative instructions. Write them
  the way you'd write a clear runbook: imperative, structured, no fluff.
- Keep SKILL.md under ~32 KB — that's the LLM-review truncation cap.
- Put extended reference material in sibling `.md` files; they're bundled
  but only `SKILL.md` is parsed for frontmatter.
- A good `description` answers "when should an agent use this skill" in
  one sentence. The selector LLM only sees that line, not the body.
