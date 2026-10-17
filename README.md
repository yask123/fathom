# Fathom

**Read a pull request as a story.**

When an agent writes the code and a bot checks it does what it says, reading the diff line by line is no longer the
job. The job is understanding the move: what was wrong, the one idea that fixes it, how things flow now, the choices
made along the way, and what changes for the rest of the system. Fathom tells you that, one page at a time, each page
a sentence and a small diagram, with the code one click away. It runs on your own
[GitHub CLI](https://cli.github.com) and [Claude Code](https://code.claude.com), so there's no Fathom account, server
or API key.

![The story of a pull request at a glance: the problem, the idea, how it works now, the choices, the promises that change, and where to read](docs/story.png)

- **Overview**: the whole PR in five sentences. Often that's enough to know what you're looking at.
- **Problem**: how things went before, as a short sequence diagram, with the step where it hurt marked. Point at an
  actor to follow only its part.
- **Idea**: the key idea in a sentence, and the few parts that carry it, new ones in green. Point at a part to see
  only what it touches.
- **Now**: the same story told again after the change, new steps in green and what travels on every arrow. Flip
  to Before to compare.
- **Choices**: the design decisions a staff engineer would want to know about, each drawn as a fork: what was
  chosen, what it was chosen over, and why, marked when the PR says so and when it's inferred.
- **Promises**: the interfaces whose shape changes (endpoints, types, tables, config), member by member.
- **Code**: the two to four hunks to read if you read nothing else.

Around the story, the app stays out of the way: pick a repository, see its open pull requests (or only the ones
waiting for you), pick one. **Changes** has the whole diff in chapters marked *read*, *skim* or *skip*, with the
conversations already on GitHub (people's and bots') on the lines they're about; click a line number to comment, reply
in a thread, or suggest a change. **Ask** (`⌘K`) puts the repo at the PR's head in front of Claude; **Review** posts
your comments, replies and a verdict to GitHub as you. A PR you've read before opens instantly; a new one's story fills
in within half a minute.

![How it works now: a sequence diagram from You to WalkingView, WalkModel, RoutePlanner and localQuestion, new steps in green with the data they carry](docs/now.png)

## Install

1. Download [**Fathom.dmg**](https://github.com/yask123/fathom/releases/latest/download/Fathom.dmg) (or pick a version
   from [Releases](https://github.com/yask123/fathom/releases)) and drag Fathom into Applications. It's signed and
   notarized by Apple. Needs macOS 26 or later (Apple silicon or Intel).
2. Open it. The first screen checks the two tools Fathom runs on and walks you through what's missing:
   - **GitHub CLI**: `brew install gh` ([other ways](https://cli.github.com)). Then press **Sign In to GitHub** in
     Fathom: it shows a one-time code, opens github.com, and finishes by itself. Already signed in with `gh auth login`?
     Nothing to do.
   - **Claude Code**: `curl -fsSL https://claude.ai/install.sh | bash` ([install guide](https://code.claude.com/docs/en/setup)).
     Then press **Open Terminal to Sign In**, or run `claude auth login` yourself. Readings use your Claude plan.

You can come back to this any time in **Settings** (`⌘,`), along with the model (Opus or Sonnet) and whether to read
new review requests in the background (off by default).

Fathom finds `gh` and `claude` the way your Terminal does: it reads your login shell's environment once at launch, so
Homebrew, nvm, mise, Volta, `~/.local/bin`, proxies, `GH_HOST` and `CLAUDE_CONFIG_DIR` all carry over.

## What leaves your Mac

- **GitHub**, through `gh` and your login: your inbox, the PRs you open, and a shallow checkout of a PR's head commit
  so Claude can look around. A review is posted only when you submit it from the review sheet.
- **Claude**, through Claude Code on your plan: the diff, and read-only access (`Read`, `Grep`, `Glob`) to that
  checkout. These runs leave out your MCP servers, hooks and slash commands.
- **Nothing else.** No analytics, no Fathom servers. Readings, caches and checkouts stay in
  `~/Library/Application Support/Fathom` (Settings → Show in Finder).

## Using it

Paste a PR link or `owner/repo#123` into the field on the home screen or at the top of the inbox (`⌘L`), or pick one
from the inbox: PRs waiting for your review, your own, and ones you've reviewed.

Fathom registers `fathom://`. Save this as a bookmark and click it on any GitHub PR page:

```
javascript:location.href='fathom://'+location.href
```

| | |
|---|---|
| `⌘1` `⌘2` | Story, Changes |
| `←` `→` | turn the story's pages |
| `⌘K` | Ask Claude about the PR |
| `⌘↩` | Review |
| `J` `K`, `N` `P`, `X` | next and previous change, next and previous chapter, mark a chapter understood |
| click a line number | comment on that line; `⌘↩` adds it to your review, `Esc` closes the box and keeps what you typed |
| `⇧⌘R` | read the PR again |
| `⇧⌘O` | open on GitHub |
| `⌘R` | refresh the inbox |
| `⌃⌘S` | show or hide the inbox |

## Build from source

Needs the Xcode 27 command line tools. No Xcode project; `swiftc` builds the app straight from `Sources/`.

```sh
./build.sh            # build into build/Fathom.app (ad-hoc signed, for your own Mac)
./build.sh --run      # build and open
./build.sh --install  # build, copy to /Applications, launch
FATHOM_ARCHS="arm64 x86_64" ./build.sh   # universal
```

`scripts/release.sh <version> <build>` makes the notarized DMG in `dist/`. It needs a Developer ID identity and a
`notarytool` profile, named by `FATHOM_SIGN_ID` and `FATHOM_NOTARY_PROFILE`, and the Mac unlocked while it runs (macOS
keeps the notary credentials out of reach while the screen is locked). Upload the DMG to the release as `Fathom.dmg`
so the download link above keeps pointing at the newest one.

## How it works

| | |
|---|---|
| Setup | `Setup.swift` reads the login shell's environment, checks `gh api user` and `claude auth status`, and reads `claude --help` so an older Claude Code gets only the flags it understands. GitHub sign-in is `gh auth login --web` with the one-time code shown in the app |
| GitHub | `gh api graphql` for your repositories, a repository's open PRs, the inbox and PR details (with its review threads and conversation), `gh pr diff` for the diff, `gh api …/reviews` to post a review and `…/comments/{id}/replies` for replies |
| Outline | `claude -p --json-schema` over the diff with every hunk labelled (`f3h2`): headline, chapters, the interfaces whose shape changes, one note per hunk. Long prose and data files are trimmed to their first lines. Streams in, headline first |
| Story | the problem as steps before (and where it hurt), the idea and the parts that carry it, the steps after with what travels, the choices (stated or inferred), and the hunks to read. `claude -p --json-schema` with read-only `Read Grep Glob` in a shallow checkout of the PR head (`git fetch --depth=1 --filter=blob:none pull/N/head`, one worktree per PR, the 12 most recent kept). It waits at most 1.5 s for the checkout, else tells it from the diff alone; pages fill in as they're written |
| Cache | Claude's readings per PR commit in `soundings/`, each PR's details and diff in `prs/`, and the inbox in `state.json`, all under `~/Library/Application Support/Fathom`. The top of the inbox is fetched ahead in the background |

Sources: `Setup.swift` (accounts), `Shell.swift` (child processes), `GitHub.swift`, `Diff.swift` (parser, noise
rules), `Claude.swift` (CLI stream, partial JSON), `Analyst.swift` (prompts and schemas), `Library.swift` (caches,
checkouts), `Store.swift` (state), and the views: `Story.swift` (the pages, the sequence diagrams, the idea graph,
the choice cards), `RootView.swift` (the repository and its pull requests), `ChangesView.swift`. The continuous motion
(sonar, pings) is Core Animation in `CoreAnimated.swift`, so the app does no work per frame.

## QA switches

Environment variables for screenshots and tests (`tools/shoot.sh out.png VAR=value …` launches a separate instance
with them and captures its window; `SHOOT_QUIET=1` leaves it where it opens instead of pulling it to the front):

| | |
|---|---|
| `FATHOM_OPEN=owner/repo#123` | open a PR on launch |
| `FATHOM_HOME=/path` | use another data folder |
| `FATHOM_SETUP=gh:signedOut,claude:missing` | show a setup state without touching the real tools; add `signin`, with `GH_CONFIG_DIR` set to an empty folder, to try GitHub sign-in |
| `FATHOM_SETTINGS=1` | open Settings on launch |
| `FATHOM_NO_AI=1` | don't call Claude |
| `FATHOM_NO_CHECKOUT=1`, `FATHOM_NO_PREFETCH=1` | no checkout of the repo; no fetching ahead |
| `FATHOM_TAB=changes`, `FATHOM_BY_FILE=1` | start on a view |
| `FATHOM_PAGE=idea` | open the story on a page (overview, problem, idea, now, choices, promises, code) |
| `FATHOM_SCROLL=line:f4h1:90`, `FATHOM_GO=f3h2` | jump in Changes |
| `FATHOM_ASK="…"` (empty just opens it), `FATHOM_REVIEW=1`, `FATHOM_INFO=1` | ask a question, open the review sheet, open the details and conversation |
| `FATHOM_COMMENT=path:line`, `FATHOM_DRAFT="…"`, `FATHOM_ADD=1`, `FATHOM_REPLY=<thread id>` | open a comment box on a line (filled, or added to the review), or a reply in a thread |
| `FATHOM_WINDOW=1188x884`, `FATHOM_NO_HOVER=1` | size the window; ignore the pointer (clean screenshots) |
| `FATHOM_SIDEBAR=0`, `FATHOM_MUTE=1` | hide the sidebar, no sonar ping |
| `FATHOM_DUMP_PROMPT=/path` | write the reading prompt to a file |

## Website

`site/fathom/` is the page at [yask.dev/fathom](https://yask.dev/fathom): one HTML file and screenshots of the app.
Preview with `python3 -m http.server 4360 --directory site` and open `/fathom/`.

## License

[MIT](LICENSE)
