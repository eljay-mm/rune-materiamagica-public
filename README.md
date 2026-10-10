# rune-materiamagica

My personal setup for playing **Materia Magica** (a text-based online RPG — a
"MUD") using the **Rune** client.

## What is this?

Materia Magica is played entirely in text: you type commands like `north` or
`kill rat` and the game describes what happens. Rune is the program that
connects you to the game — think of it as a web browser, but for text games.
It runs in your terminal and is customized with little scripts written in Lua.

This repo is my collection of those scripts. Together they turn the plain
text game into something much friendlier: a map of every room you explore,
health bars, a quest tracker, a chat sidebar, and a bunch of autopilot
helpers.

Nothing here is required to play — it's all quality-of-life stuff I built up
over time.

## Getting started

1. **Install Rune** — grab it from [runemud.com](https://runemud.com) and make
   sure the `rune` command works in your terminal.
2. **Copy these files** into Rune's config folder:
   - Linux / macOS: `~/.config/rune/`
   - Windows: `%APPDATA%\rune\`
3. **Connect**:
   - `rune` — connects to Materia Magica; type your character name at the
     prompt.
4. **After editing any script**, just type `/reload` inside Rune — no restart
   needed.

## Updating

Type `/update` in the client to pull the latest version from the public repo;
a one-line notice also appears on startup when a newer version exists.
`/update check` just reports whether you're current. Your map and settings are
never touched.

## What you get

**The screen layout** (`init.lua`, `panes.lua`)
A top bar with your character name, level, gold on hand, bank balance, quest
points, and practices. Below that: the game output, a chat sidebar, and a
quest sidebar. `/panes` hides the sidebars when you want a clean full-width
view (handy for copying text).

**Auto-mapper** (`mapper.lua`, `mapper_store.lua`, `mapper_graph.lua`,
`mapper_walk.lua`)
Builds a map of every room you visit and saves it (`mapper/map.db`). Then:
- `mapper goto <room>` / `mapper path <room>` — walks you there step by step
- `mapper where` — where am I?
- `mapper bookmark` — name rooms you want to remember
- `mapper nearby` — what's around me
- Tag death-trap rooms so the pathfinder routes around them
- Walks go one step at a time and wait for the game to confirm each move, so
  they never get lost or desynced. `mapper stop` bails out anytime.

**Speedwalk shortcuts** (`spdr.lua`)
Type `spdr <shortcut>` (like `spdr bank`) to walk to a saved destination.
Comes pre-loaded with a bunch of common destinations; add your own with
`spdr add <shortcut> <room#> <description>`. Typing part of a name opens a
searchable picker.

**Roadsign picker** (`sign.lua`)
Look at any roadsign in the world and a picker pops up listing everywhere it
points; choose one and it runs you there over MM's roadsign network.

**Sense autowalk** (`sense.lua`)
When the game tells you "You sense that X may be located n, n, e…", it just
walks there for you. `sense off` turns that off.

**Quest tracker** (`quests.lua`)
A sidebar that lists your active quests with checklists of each phase and
countdown timers. Viewing a quest in-game (`quest status <number>`) pulls up
its details automatically.

**Chat sidebar** (`comms.lua`)
Collects tells, clan chat, PK talk channels, relay, formation tells,
alliance chat, novice clan, and auction into one pane so they don't
scroll away in the main output. Filter with `comms tell`, `comms clan`,
`comms talk`, `comms relay`, `comms form`, `comms ally`, `comms novice`,
`comms auction`, or `comms all`. Scroll it with `ctrl+alt+pgup` /
`ctrl+alt+pgdn`. History survives restarts and is keyed per character.
`comms debug` and `comms name` for troubleshooting.

**Health bars** (`stats.lua`, `enemy.lua`)
- The prompt bar is off by default; `promptbar on` turns your
  `<1234hp 567sp 890st>` prompt into a color bar (green/yellow/red HP bar, blue
  SP bar, yellow ST bar).
- Monsters' wound descriptions ("has some very significant wounds…") become
  inline health bars with a percentage, so you can see exactly how hurt
  something is.

**Auto-pouch** (`autopouch.lua`, `cook/recipes.json`)
The Pouch of Plenitude spits out random cooking ingredients. This empties it
automatically, keeps the ingredients for the recipes you've picked (53 recipes
included — bagels, borracho, and the rest), and drops the junk. `autopouch
pick` opens a checkbox list of recipes; `autopouch daily` picks one extra item
to keep for the daily quest.

**Terrain in room headers** (`terrain.lua`)
Stamps the room's terrain (diggable, sheltered, underwater…) right into the
room header line as you walk in.

**Anti-idle** (`timers.lua`)
Sends `twiddle` every 5 minutes so you don't get logged out for idling.

## Commands cheat sheet

| What | How |
|---|---|
| Walk somewhere | `mapper goto <room#>` or `spdr <shortcut>` |
| Where am I | `mapper where` |
| Stop walking | `mapper stop` / `sense stop` |
| Signpost travel | look at a sign; pick a destination |
| Quest sidebar | automatic; `quests hide` to hide |
| Chat filter | `comms tell` / `comms clan` / `comms all` … |
| Hide sidebars | `/panes` |
| Pick cooking recipes | `autopouch pick` |
| Empty the pouch now | `autopouch now` |
| Reload scripts | `/reload` |

## Notes

- Your settings (selected recipes, bookmarks, chat history…) are saved
  automatically and survive restarts.
- The room database (`mapper/map.db`, ~6.5 MB of mapped rooms) and the
  speedwalk list (`mapper/spdr.json`, 238 destinations) are committed to the
  repo, so a fresh clone starts with your map intact. Only live runtime files
  — your position, `store.json`, and local server scratch files — are
  git-ignored.
- Built against the Rune client API documented at
  [runemud.com](https://runemud.com). If Rune updates and something breaks,
  that's the fastest path to fixing it.
