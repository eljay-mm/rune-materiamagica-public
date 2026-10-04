# Rune — AI Authoring Guide

A guide for an AI writing Rune MUD client configuration, scripts, and triggers. Rune is configured in Lua. One script (`init.lua`) loads at startup; everything is registered from it. Read the linked pages on runemud.com for full signatures — this guide is the model and the rules of thumb, not the reference manual.

Sources: every page under https://runemud.com/getting-started/, /scripting/, /interface/, /cookbook/, and /reference/api/, plus /reference/slash-commands/ and /reference/protocols/. Fetched and distilled into a single document so a code-generating AI does not have to.

---

## 1. Mental model

Rune is a terminal MUD client written in Go. The user's config is a Lua script that registers handlers with the client at startup.

- **Single entry point:** `~/.config/rune/init.lua` (Linux/macOS), `%APPDATA%\rune\init.lua` (Windows). Auto-loaded.
- **Edit/reload loop:** edit the file, type `/reload` in the client, keep playing. The Lua VM is rebuilt; `rune.session` and `rune.store` survive; in-memory Lua variables do not.
- **No DSL.** Every alias, trigger, timer, hook, keybind, GMCP handler, custom command, bar, and picker is a Lua function (or string) registered through the `rune.*` API.
- **Everything is a registry.** Aliases, triggers, timers, hooks, binds, bars, commands, and GMCP handlers all share the same lifecycle: create → optional name → optional group → optional priority → enabled by default → replaceable on re-registration → individually disableable → auto-quarantined after 3 consecutive errors.
- **One source of truth per concept:** names, options, handles, string-vs-function actions, the context object, the priority queue, and the quarantine rule are described once in [The Scripting Model](https://runemud.com/scripting/model/) and referenced from every other page. Read that page once.

The binary lives in `$PATH` as `rune`. Launch with `rune host port [tls]` or `rune worldname` (a bookmark). Configurable via `--config-dir PATH` or `RUNE_CONFIG_DIR`.

---

## 2. Authoring rules

These rules are how the docs tell you to write working Rune scripts. Encode them.

### 2.1 Script structure

- Put everything in `init.lua`, or split into `combat.lua`, `ui.lua`, etc. and `require("combat")` them from `init.lua`. `require()` paths resolve relative to the requiring script's directory — no path setup needed for siblings.
- A required file is plain Lua that runs top-to-bottom. Put registrations directly in it; no module table or `return` is needed.
- `/reload` rebuilds the Lua VM, so edits to any required file are picked up.
- A script error does not bring the client down — it's reported with `file:line` and the rest of the config still loads.

### 2.2 The shared registry contract

Every registration function (`rune.alias.*`, `rune.trigger.*`, `rune.timer.*`, `rune.hooks.on`, `rune.bind`, `rune.ui.bar`, `rune.command.add`, `rune.gmcp.on`) follows the same shape:

```lua
local h = rune.trigger.contains("foo", action, opts)  -- returns a handle
h:enable()  h:disable()  h:remove()  h:name()  h:group()  h:action()
```

All `opts` accept the common fields:

| Field      | Type    | Default | Notes                                                            |
|------------|---------|---------|------------------------------------------------------------------|
| `group`    | string  | none    | Membership for batch enable/disable/remove.                      |
| `priority` | number  | 50      | Run order where multiple matchers can fire. Lower runs first.    |
| `once`     | bool    | false   | Auto-remove after first match (aliases, triggers).               |
| `name`     | string  | —       | Some functions infer the name from their first arg (see below).  |

Naming rules — important to get right:

- `rune.bind`, `rune.ui.bar`, `rune.command.add`, `rune.alias.exact`: the first argument is itself the name. `opts.name` is ignored with a notice.
- `rune.trigger.*`, `rune.alias.regex`, `rune.timer.*`, `rune.hooks.on`, `rune.gmcp.on`: you supply `opts.name`.
- Re-registering the same name replaces the old registration. This is what stops `/reload` from stacking duplicates — name anything you expect to re-register.

Management is identical across all registries (most namespaces are singular: `rune.trigger`, `rune.alias`, `rune.timer`, `rune.hooks`, `rune.command`, `rune.gmcp`. Two are plural for historical reasons: `rune.binds` for key bindings and `rune.bars` for status bars — the registration functions are still singular: `rune.bind` and `rune.ui.bar`):

```lua
rune.trigger.list()       -- all triggers with state, group, file:line
rune.trigger.get(name)
rune.trigger.enable(name) / disable(name)
rune.trigger.remove(name)
rune.trigger.remove_group("combat")
rune.trigger.clear()
```

The matching slash commands are `/triggers`, `/aliases`, `/timers`, `/hooks`, `/binds`, `/bars`, `/commands`, `/groups`, `/gmcp`. Use them during development. `/group <name> on|off` toggles a group mid-game.

### 2.3 String vs. function actions

Most registries accept either:

- **String** — sent as a command. For regex triggers/aliases, `%1`, `%2`, … are substituted from captures. For exact aliases, whatever you typed after the matched phrase is appended (so `rune.alias.exact("k", "kill")` makes `k rat` send `kill rat`).
- **Function** — full control. Return `nil` to pass the line through, a string to rewrite it, or `false` to gag it. For input hooks, `false` cancels the submission entirely.

Default to strings for canned responses. Switch to functions when you need state, conditionals, capture processing, or to rewrite/gag the output.

### 2.4 The context object

Function actions receive `(args_or_matches, ctx)`:

| Field           | Present in                                | Meaning                                       |
|-----------------|-------------------------------------------|-----------------------------------------------|
| `ctx.name`      | all                                       | The item's name                               |
| `ctx.group`     | all                                       | The item's group                              |
| `ctx.type`      | all                                       | `"alias"`, `"trigger"`, `"timer"`, `"hook"`   |
| `ctx.line`      | triggers, output/prompt hooks             | A line object with `:raw()` and `:clean()`    |
| `ctx.args`      | exact alias functions                     | Text after the matched phrase                 |
| `ctx.matches`   | regex aliases and triggers                | Capture array                                 |
| `ctx.text`      | multi-line triggers (span)                | Whole collected block                         |
| `ctx.lines`     | multi-line triggers (span)                | Individual line objects                       |
| `ctx:remove()`  | all                                       | Unregister from inside the callback           |

### 2.5 Quarantine

A callback that throws **three times in a row** is auto-disabled with a notice. This prevents one buggy script from flooding the screen or wedging input. Recovery: fix the bug, then `h:enable()` / `rune.<reg>.enable(name)` / `/reload`. One successful run clears the count.

**Authoring implication:** if a script might run on lines where its assumptions don't hold (combat trigger on a room description, etc.), check state before assuming — silent no-op is better than a thrown error that costs you three quarantines and a silent trigger.

### 2.6 Priority model

Lower priority runs first. The core's output/prompt/echo handlers sit at priority 100. Useful anchor points:

- **< 100**: see the line before triggers/style/echo process it. Use for loggers that want every raw line (including gagged).
- **100**: core handlers. Default for most triggers.
- **> 100**: see the post-trigger, post-style result. Use for loggers that want the screen view.

The `log-output` and `log-echo` policy hooks run at 200. The `history-expansion` input hook runs at 100.

### 2.7 Common pitfalls

- Regex is **Go RE2**, not Lua patterns. `\\d`, `\\w`, `\\s` work; no backreferences, no lookaround; `\\d` is escaped twice in Lua source (`"\\d+"`). Validated at registration — bad patterns raise immediately.
- Triggers match the **clean** (ANSI-stripped) line. Use `raw = true` to match the raw line.
- String actions only **send**. They never rewrite, gag, or inspect the line — those are function-return features plus the `gag` option.
- `%N` substitution is **only** in regex string actions. Exact-alias string actions append arguments at the end — use a regex or a function to splice them in the middle.
- Aliases can recurse (an alias that expands to another alias's input) up to depth 100.
- `/reload` clears timers and bar registrations. Re-create them in `init.lua` if you want them to survive reloads.
- A disabled bind consumes its key (no fallthrough to typing). Use `rune.unbind(key)` if you want normal fallthrough back.
- Disabling a one-shot timer while it's due removes it without firing — create a new timer if you still need it.

---

## 3. Triggers

React to server output. The two decisions: **how to match** (exact / starts / contains / regex) and **what to do** (send a string, run a function).

```lua
-- String action: send a command on match
rune.trigger.contains("You are hungry", "eat bread")

-- Function action: capture and decide
rune.trigger.regex("^Your health is (\\d+)%\\.$", function(m)
    if tonumber(m[1]) < 30 then
        rune.send("quaff heal")
    end
end)

-- Highlighter: return a string to rewrite the line
rune.trigger.contains("You are hit", function(_, ctx)
    return rune.style.red(ctx.line:clean())
end)

-- Gag: hide the line
rune.trigger.contains("The shopkeeper hums", nil, { gag = true })
```

Return values from a function trigger:

- `nil` — line passes through unchanged.
- a string — line is rewritten; later triggers see and match the rewritten text.
- `false` — line is gagged.

**Composing triggers:** because rewrites chain, a highlighter and a tagger compose naturally. The latter receives the styled line as input.

### 3.1 Prompt triggers

For login/command prompts that arrive without a newline, use `on = "prompt"`:

```lua
rune.trigger.contains("Username:", "Ragnar", { on = "prompt", once = true })
```

Prompt observations may repeat as the partial line grows. Make handlers idempotent or use `once = true` for one-shot work (login). Function actions receive `ctx.confirmed` (`true` when a Telnet GA/EOR boundary confirmed the prompt). Prompt triggers can rewrite or gag the displayed prompt (rewrites chain) but cannot use `span` (spans collect complete output lines).

### 3.2 Multi-line triggers (span)

For wrapped chat, score sheets, who lists:

```lua
rune.trigger.regex("^(\\w+) tells you: (.+)$", function(m, ctx)
    rune.pane.write("chat", "[Tell] " .. m[1] .. ": " .. m[2])
end, { name = "tells", span = { to = "\\x1b\\[0?m\\s*$", raw = true, max = 8 } })
```

`span.to` is the regex for the terminating line (inclusive). `span.raw` matches it against the raw line (needed when the terminator is an ANSI reset). `span.max` is the safety cap (default 8). For fixed-shape blocks, use just `max = N`.

In the action: `ctx.text` is the **last capture** plus continuation lines space-joined (for the literal modes it's the whole clean line). `ctx.lines` is the array of line objects. Return values are ignored — the lines have already been shown. Use `gag = true` if you want to hide the whole block.

### 3.3 Testing triggers

```lua
/test <line>      -- run one fake complete line through output triggers
/test              -- multi-line spans collect across multiple calls
```

Prompt triggers are not exercised by `/test`. Test those by sending real input that triggers them.

---

## 4. Aliases

Rewrite what the user types before it reaches the server. Two matchers: `exact` (leading phrase, literal) and `regex` (whole line, Go regexp).

```lua
-- Exact: simple expansion, args are appended
rune.alias.exact("gc", "get all from corpse")
-- "gc" → "get all from corpse"
-- "gc bag" → "get all from corpse bag"

-- Multi-word exact: matches as the leading words
rune.alias.exact("chat off", "chatlog off")
-- "chat off now" → "chatlog off now"

-- Regex: capture and reorder
rune.alias.regex("^gr (.+)$", "get %1;wear %1")

-- Function: logic + send
rune.alias.exact("heal", function(args, ctx)
    rune.send("cast 'heal' " .. (args ~= "" and args or "self"))
end)
```

Regex aliases are checked first, in priority order. If none match, exact aliases are tried; among them, the **longest active phrase wins**. Only one alias fires per command.

A function alias's return value: a string feeds back through `rune.send` (so aliases can build on aliases), or `nil`/nothing consumes the input entirely (the function already did the work).

---

## 5. Timers

```lua
rune.timer.after(5, "stand")                            -- one-shot
rune.timer.every(60, "save", { name = "autosave" })     -- repeating

-- Self-cancelling retry
local tries = 0
rune.timer.every(2, function(ctx)
    tries = tries + 1
    rune.send("open gate")
    if tries >= 10 then ctx:remove() end
end)
```

A function timer's `ctx` carries `name`, `group`, `type`, and `ctx:remove()`. For repeating timers, the next countdown starts when the timer becomes due, not when the action finishes.

Useful management:

```lua
local h = rune.timer.every(60, "save", { name = "autosave" })
h:remaining()       -- seconds until next fire (with fractions; nil if gone)
rune.timer.list()   -- all timers with their remaining time
rune.timer.cancel(name)  -- alias for remove
```

**Important:** a one-shot that becomes due while disabled is removed without firing — enable won't bring it back; create a new timer. `/reload` clears all timers — recreate them in `init.lua`.

---

## 6. Hooks and events

Hooks intercept the data pipeline. Triggers are for matching specific text; hooks are for inspecting every line, timestamping, mirroring, or reacting to lifecycle events (connect, reload, errors).

```lua
rune.hooks.on(event, handler, opts?)
```

### 6.1 Data-flow events

| Event    | Receives                          | Notes                                                  |
|----------|-----------------------------------|--------------------------------------------------------|
| `input`  | submitted text, context           | Before local echo, history, and command/verbatim processing. `false` cancels. |
| `output` | line object (`:raw()`, `:clean()`)| Once per complete server line. `false` gags.           |
| `prompt` | line object, `confirmed` bool     | Cumulative partial-line observation (`false`) or GA/EOR-confirmed prompt (`true`). |
| `echo`   | one display-safe physical line    | After input rewrites; skipped while server hides echo. |

Return values chain: `nil` passes through, a string replaces the text for the next handler, `false` ends the chain (gag/hide/cancel).

For `input`, the second argument `context` is read-only with `context.mode == "command"` or `"verbatim"`. The handler sees the rewrite from the previous handler. A string rewrite controls local echo, history, and command processing. To send multiple physical lines from a command handler, call `rune.send_raw(...)` and return `false` so Rune doesn't also process the original command. For history expansion: input handlers with priority < 100 see the text before `history-expansion` runs; those > 100 see the expanded text.

### 6.2 Notification events

Return values ignored; all handlers run.

| Event                  | Args                  | When fired                                    |
|------------------------|-----------------------|-----------------------------------------------|
| `ready`                | none                  | After scripts load during startup or `/reload`, before Rune applies settings/UI |
| `connecting`           | address               | Dial started                                   |
| `connected`            | address               | Connection established                         |
| `disconnecting`        | none                  | Disconnect requested                           |
| `disconnected`         | none                  | Connection closed                              |
| `reloading` / `reloaded` | none                | Around `/reload` (order: `reloading`, `ready`, `reloaded`) |
| `loaded`               | path                  | After `/load` or `rune.load` loads a file (not for startup auto-load) |
| `error`                | message               | On reported errors                            |
| `input_changed`        | text                  | Whenever the input buffer changes (typing, paste, history, completion, `rune.input.set`, post-submit draft) |
| `window_size_changed`  | width, height         | On first reported terminal size and every resize; `rune.state.width`/`height` already hold the new values |
| `gmcp`                 | package, data, raw    | On every GMCP message, before package-specific handlers |
| `gmcp_enabled`         | none                  | GMCP negotiated; the core handler sends `Core.Hello` |

### 6.3 Replacing built-in handlers

The named core handlers are registered with stable names so you can disable or replace them. Full list: `log-output`, `log-echo` (logging policy, priority 200), `gmcp-hello` (GMCP handshake), `gmcp-reset`, `first-run-welcome`, `history-expansion` (interactive history expansion, priority 100), and `_completion_cache` / `_completion_input` (tab-completion word harvesting, priority 200). Disable one before adding your own to replace it cleanly:

```lua
rune.hooks.disable("log-output")
rune.hooks.on("output", function(line)
    rune.log.write(os.date("[%H:%M:%S] ") .. line:clean())
end, { priority = 200 })
```

For `echo`, the core's `>` prefix is the default — replace with a custom style:

```lua
rune.hooks.on("echo", function(text)
    return rune.style.cyan("» " .. text)
end, { priority = 50 })
```

### 6.4 Wrap a built-in (preserve + extend)

To extend the default `pgup` (scroll) behavior instead of replacing it:

```lua
local scroll = assert(rune.binds.get("pgup")):action()
rune.bind("pgup", function()
    scroll()
    rune.echo("scrolled")
end)
```

The same pattern works for slash commands (`rune.command.get("quit")`) and any other handler.

---

## 7. Key bindings

```lua
rune.bind("f1", function() rune.send("cast shield") end)
rune.bind("ctrl+g", function() rune.pane.toggle("map") end)
rune.unbind("f1")
```

Callbacks must be functions (no string form). Use `rune.send` inside.

### 7.1 Key names

- Printable: `"j"`, `"/"`, `"."`, `"space"` (for space).
- Editing: `"esc"`, `"tab"`, `"backspace"`, `"delete"`, `"insert"`.
- Navigation: `"up"`, `"down"`, `"left"`, `"right"`, `"home"`, `"end"`, `"pgup"`, `"pgdown"`.
- Function: `"f1"` … `"f63"`.
- Numpad: `"numpad0"` … `"numpad9"`, `"numpad_dot"`, `"numpad_slash"`, `"numpad_star"`, `"numpad_minus"`, `"numpad_plus"`, `"numpad_enter"`. Requires `rune.config.set("numpad", true)` and a terminal that supports it: Kitty, Ghostty, Alacritty, foot, iTerm2 (Kitty protocol — no setup), WezTerm (`enable_kitty_keyboard = true`), Windows Terminal 1.25+ (Kitty protocol), macOS Terminal via Profiles → Advanced → "Allow VT100 application keypad mode" (DEC keypad), xterm with `-kt vt220` NumLock off (DEC keypad), urxvt NumLock off (DEC keypad). GNOME Terminal, Ptyxis, COSMIC Terminal don't preserve the physical keypad.
- Modifiers in order: `ctrl+alt+shift+meta+hyper+super` then base. E.g. `"ctrl+alt+x"`.

Names are exact. Use `esc`, `pgup`, `pgdown` — `escape`, `pageup`, `pagedown` are not aliases.

### 7.2 Where binds run

Printable binds only fire on an empty/fully-selected input line; otherwise the character is typed. Non-printable binds always run when not in a modal picker/scrollback search/composer. Bracketed paste never triggers a bind.

### 7.3 Default keymap (replaceable)

`ctrl+r` history, `ctrl+f` scrollback, `ctrl+t` aliases, `/` slash-completion, `ctrl+c` clear/quit, `ctrl+u` clear, `ctrl+w` / `alt+backspace` delete-word, `up`/`down` history, `alt+left`/`alt+right` word movement, `tab` completion, `ctrl+e` `$EDITOR`, `pgup`/`pgdown` scroll, `ctrl+home`/`ctrl+end` jump. Bare `home`/`end` are unbound (they move the input cursor).

### 7.4 Reserved keys

These actions are built in and do not dispatch Lua binds. In normal input: `enter` submits; `ctrl+enter`/`ctrl+j` start a composer newline. In the composer: `enter` submits using the displayed mode; `alt+v` toggles Command/Verbatim; `alt+enter` runs the draft as a command once; `ctrl+enter`/`ctrl+j` insert a newline. The inline picker closes before `alt+v` or `alt+enter` acts on the draft; modal pickers and scrollback search capture those keys. Terminals that cannot distinguish Ctrl+Enter report it as Ctrl+J.

---

## 8. Slash commands

```lua
rune.command.add("greet", function(args)
    rune.send("say Hello, " .. (args ~= "" and args or "everyone") .. "!")
end, "Greet someone")
```

The handler receives a single string (everything after `/name`); `""` for no args. The description appears in `/help` and the `/` picker. Re-adding a name replaces the old handler. Unknown commands report `[Error] Unknown command: /x` and are never sent to the server — use `/raw /text` if a game wants a literal slash. A disabled command still consumes its input (with an error message).

---

## 9. GMCP

GMCP carries structured out-of-band data (vitals, room info, channels) as JSON over telnet option 201. Rune decodes the JSON; handlers receive real Lua tables.

```lua
rune.gmcp.subscribe("Char")
rune.gmcp.on("Char.Vitals", function(data, package)
    -- data is a Lua table; package is the name as sent
    rune.store.set("hp", data.hp)
    rune.ui.refresh_bars()
end, { name = "vitals" })
```

Matching is case-insensitive and exact (`"Char.Vitals"` does not catch `"Char.Vitals.Max"`). For every message regardless of package, use the `"gmcp"` hook with `(package, data, raw_json)`.

To send: `rune.gmcp.send("Char.Skills.Get")` (bare) or `rune.gmcp.send("Core.Hello", { client = "rune", version = rune.version })`. Returns `true`, or `nil, err` if GMCP isn't negotiated or the value isn't encodable. Failures are also echoed to the screen.

The handshake: when the server negotiates GMCP, the `gmcp_enabled` event fires and the core `gmcp-hello` handler sends `Core.Hello` plus your subscription set. Subscriptions declared at load time are picked up automatically on connect.

Debugging:

```
/gmcp                       -- negotiation state, subscriptions, handlers
/gmcp send Char.Skills.Get {}
```

---

## 10. HTTP

Asynchronous. The request runs off the event loop; the callback runs back on it. Slow networks never freeze the UI.

```lua
rune.http.get("https://api.example.com/who", function(resp, err)
    if err then
        rune.echo("[who] " .. err)
        return
    end
    if resp.status ~= 200 then
        rune.echo("[who] HTTP " .. resp.status)
        return
    end
    rune.echo("[who] " .. resp.body)
end)

rune.http.post(url, body, { headers = { ["Content-Type"] = "application/json" } }, callback)
```

`opts` = `{ headers = {...}, timeout = 30 }`. Body is sent as-is — no default Content-Type. Response = `{ status, body, headers }`. `err` is set only for transport failures (DNS, timeout, TLS, unsupported scheme, body > 5 MB); a 4xx/5xx is a response, not an error. Up to 10 redirects are followed.

`/reload` drops pending callbacks (the Lua VM is gone). A request still in flight completes and its late result is silently discarded.

Always **percent-encode untrusted text** when building form bodies — game text goes into the body and an attacker-controlled `&` would inject structure. The Telegram cookbook has a reusable `urlencode` helper.

---

## 11. Storage

Three lifetimes:

| Mechanism      | Survives `/reload` | Survives exit | Values                       |
|----------------|--------------------|---------------|------------------------------|
| Lua variables  | no                 | no            | anything                     |
| `rune.session` | yes                | no            | strings only                 |
| `rune.store`   | yes                | yes (disk)    | strings, numbers, bools, JSON-able tables |

```lua
-- Session: combat toggles, mid-session scratch
rune.session.set("kills", tostring(kills))
kills = tonumber(rune.session.get("kills") or "0")
rune.session.delete("kills")

-- Durable: settings, bookmarks, anything you want to keep
rune.store.set("prefs", { autoloot = true, greet = "Hail, %s!" })
local prefs = rune.store.get("prefs") or {}
rune.store.delete("prefs")           -- or rune.store.set("prefs", nil)

-- World bookmarks: stored under the "worlds" key
rune.world.add("viking", "vikingmud.org:2001")
rune.world.add("secure", "mud.example.com:4000", { character = "Ragnar" })  -- extra opts stored verbatim
```

`store.json` is pretty-printed, hand-editable when the client is closed, plaintext on disk. Don't put passwords in it — use the environment or type them yourself.

---

## 12. Layout, panes, and bars

The terminal is a tree of `row` / `column` containers with leaf types `pane`, `bar`, `input`, `separator`.

```lua
rune.ui.layout({
    type = "column",
    children = {
        { type = "pane", name = "chat", size = 10, hidden = true },
        { type = "pane", name = "output", border = "none" },
        { type = "input" },
        { type = "bar", name = "status" },
    },
})
```

### 12.1 Size grammar

- Integer (e.g. `40`) — fixed cells.
- `"N%"` — percent of parent's allocatable extent.
- `"Nfr"` — weighted share of remaining space.
- `"auto"` — measured height; only valid as a column child.
- Omitted — `"1fr"` on pane/row/column, `"auto"` on input/bar/separator in a column.

`min_size` / `max_size` bound the same dimension. When sizes conflict, fixed/percentage/`fr` shrink first; if even minimums can't fit, gaps and minimums are relaxed to keep input reachable. Maxima are hard caps. Fixed or capped children may leave unused space at the end — include an uncapped `fr` child to fill it.

Auto heights: input measures its current editing mode, a non-empty bar uses one row, a separator uses one row, a pane measures its content at the assigned width plus frame rows. An auto-height row first assigns widths to children, then uses their tallest preferred height. Explicit `auto` widths are unsupported; omitted widths use `1fr`.

### 12.2 Leaf types

- `input` — required, exactly once. Its automatic height follows the active editor/picker/search mode. Can appear anywhere, including inside an identified region.
- `pane name = "..."` — a named scrollable buffer. Pre-create with `rune.pane.create("name")` or write into it directly (`rune.pane.write` auto-creates). Borders: `"full"` (default), `"horizontal"`, `"none"`. `title` replaces the generated header.
- `bar name = "..."` — calls a registered `rune.ui.bar` renderer every 250 ms.
- `separator` — one-row rule, optional `char` (one cell, e.g. `"═"`; default is `─`).

Containers (`row`, `column`) may have zero, one, or many children. Empty containers collapse before sizing and take no space.

The reserved `output` pane (server text) is pre-created. Place it with `{ type = "pane", name = "output" }`. Its layout placement is optional but, like any pane name, can only appear once.

### 12.3 Visibility & regions

Give a non-root container an `id` to address its whole subtree:

```lua
rune.ui.regions.show("sidebar")        -- true if found, false otherwise
rune.ui.regions.hide("sidebar")        -- nil, err if it contains input
rune.ui.regions.toggle("sidebar")      -- nil, err if hiding would remove input
rune.ui.regions.is_hidden("sidebar")   -- local hidden value; nil if unknown
```

Pane placements use the same operations by name: `rune.pane.show/hide/toggle/is_hidden("chat")`. `show`/`hide`/`toggle` return `true` when the layout places the pane, `false` otherwise; `is_hidden` returns the placement's local hidden state, or `nil` when the layout has no pane by that name. Declare `hidden = true` on a leaf to start hidden. A region may contain input but cannot be hidden while it does. Hidden nodes take no space; siblings reclaim it. Buffer contents and scroll position survive layout replacement and `/reload`; runtime visibility changes last until the next `rune.ui.layout` or `/reload`, which restore the declared `hidden` values.

### 12.4 Panes — the push model

Panes are append-only buffers. Scripts `write` lines as events happen; this is the opposite of bars, which Rune polls.

```lua
rune.pane.write("chat", styled_text)        -- append; creates the buffer if needed
rune.pane.replace("vitals", block)          -- clear + write in one UI update (use for status panels)
rune.pane.show("chat") / hide / toggle / is_hidden
rune.pane.clear("chat")                  -- no-op for unknown names
rune.pane.scroll_up("chat", 5) / scroll_down / scroll_to_top / scroll_to_bottom
```

Use `replace` for status panels (vitals, roster) — a `clear` + `write` sends two UI updates and an empty frame can flicker between them. Ordinary panes grow to 1000 lines then trim to 500. The reserved `output` pane keeps up to 100,000 rows wrapped at append time.

**Mirror pattern** — copy or move categories of output into panes:

```lua
-- Copy (keep in output too):
rune.trigger.regex("^(\\w+) tells you: (.+)$", function(m, ctx)
    rune.pane.write("chat", ctx.line:raw())
end)

-- Move (gag from output):
rune.trigger.regex("^\\[Auction\\]", function(_, ctx)
    rune.pane.write("auctions", ctx.line:raw())
    return false
end)
```

### 12.5 Bars — the poll model

```lua
local state = {}  -- data source

rune.ui.bar("vitals", function(width)
    if not state.hp then return "" end
    return string.format("HP %d/%d   MP %d/%d", state.hp, state.maxhp, state.mp, state.maxmp)
end)

-- Trigger an immediate render instead of waiting for the tick:
rune.ui.refresh_bars()
```

The callback receives the terminal width (not the bar's narrower slot). Return a string, a `{ left, center, right }` table for alignment, or `nil`/`""` for an empty bar (collapsed — takes no space). Renderers are quarantined after 3 consecutive errors; re-registering the name gives a fresh start.

**Convention:** keep the renderer cheap. Store/precompute data in the event handler that updates it (GMCP, prompt trigger), format the snapshot in the bar callback.

The `status` bar is the default — registering your own under that name replaces it completely (you take over the tab-completion matches and Ctrl+C warning too). A bar displays only when the layout contains a `bar` leaf whose name matches its registry name AND the bar is enabled AND its renderer produces visible content AND every ancestor region is visible. A same-named pane is a separate resource and never substitutes for the bar.

Bar registration and enabled state survive layout replacement (just `rune.ui.layout(...)`); `/reload` rebuilds the Lua registry, so scripts register bars again with fresh enabled and failure state.

Bar management uses the bar name (note the plural `rune.bars` namespace for management; `rune.ui.bar` registers):

```lua
rune.bars.get(name)        -- handle, or nil
rune.bars.enable(name) / disable(name) / remove(name)
rune.bars.toggle(name)     -- true when the named bar exists, false otherwise
rune.bars.list() / .count() / .clear() / .remove_group(g)
```

---

## 13. Pickers

Modal or inline fuzzy-filter overlay built on the input area.

```lua
rune.ui.picker.show({
    title = "Paths",                                  -- modal only
    items = {
        { text = "temple", desc = "safe room", value = "temple" },
        { text = "smithy", desc = "repairs",   value = "smithy" },
        -- plain strings also work as items
    },
    on_select = function(value)
        rune.send("walkto " .. value)
    end,
    mode = "modal",                -- "modal" (default) or "inline"
    match_description = false,     -- include desc in fuzzy match
    dismiss_on_space = false,      -- inline mode: close on space (good for /commands)
})
```

Built-ins:

- `/` — command picker (your commands included).
- `/connect` with no args — world picker.
- `Ctrl+R` — history search. `Ctrl+T` — alias search.

Navigation: arrows move, Enter/Tab accept, Esc/Ctrl+C cancel.

---

## 14. Logging

```lua
rune.log.start()                  -- ~/.config/rune/logs/<timestamp>.log
rune.log.start("quest.log")       -- named
rune.log.start(nil, { raw = true })  -- keep ANSI codes (view with less -R)
rune.log.stop()
rune.log.status()                 -- active path, or nil; "/log status" shows "(raw)" when on
rune.log.write(text)              -- append directly; no-op when not logging
```

The log is ANSI-stripped by default, mirrors the screen view (server output after triggers ran, gagged lines omitted), and **includes the local echo** of what Rune accepted and echoed. Prompts and client messages (`rune.echo`) are not logged. **Passwords stay out** because the echo hook doesn't fire while the server hides input.

Active logs survive `/reload` (the file handle is owned by Go, not the Lua VM) and close cleanly on exit.

To change the policy — e.g. add timestamps, log gagged lines too, change format — disable the core `log-output` / `log-echo` hooks (priority 200) and register your own:

```lua
rune.hooks.disable("log-output")
rune.hooks.on("output", function(line)
    rune.log.write(os.date("[%H:%M:%S] ") .. line:clean())
end, { priority = 200 })

-- To also capture gagged lines, register below priority 100
-- so you run before the trigger handler.
```

To auto-log every connection:

```lua
rune.hooks.on("connected", function(addr)
    if not rune.log.status() then rune.log.start() end
end)
```

---

## 15. Connection, worlds, reloading

```lua
rune.connect("mud.example.com:4000")           -- plain telnet
rune.connect("tls://mud.example.com:4000")      -- TLS, verified
rune.connect("tls+insecure://...:4000")        -- TLS, self-signed OK

rune.disconnect()
rune.reload()      -- rebuild Lua VM; rune.session survives, rune.store survives, Lua variables don't
rune.load("path")  -- run a script (true, or nil+err)
rune.quit()
```

Connection is async — use the `connecting` / `connected` hooks for follow-up.

Bookmarks (stored in `rune.store` under `"worlds"`):

```lua
rune.world.add("viking", "vikingmud.org:2001", { character = "Ragnar" })
rune.world.list()       -- [{name, address}, ...]
rune.world.get(name)    -- full entry table including extra opts
rune.world.remove(name)
```

Then `rune viking` from the shell, or `/connect viking` inside the client. `/connect` with no args opens a picker. `/reconnect` redials the last server — stored durably, survives `/reload` and restarts.

---

## 16. Input, history, editor

```lua
rune.input.get() / rune.input.set(text)
rune.input.get_cursor() / rune.input.set_cursor(byte_offset)
rune.input.word_left() / rune.input.word_right()
rune.input.delete_word()
rune.input.open_editor(initial?)   -- suspends, runs $EDITOR, returns text + ok

rune.history.get()                  -- all submitted commands, oldest first
rune.history.add(cmd)               -- append a normal-command entry; cmd must be valid
                                   -- command text; terminal controls rejected
```

Cursor positions are zero-based UTF-8 byte offsets (same byte units as Lua 5.1 string ops; `set_cursor` clamps and snaps mid-multibyte to the prior code-point). Setting text with newlines/tabs activates the visible composer (Verbatim initially).

Built-in behaviors:

- `;` separates commands; double it (`;;`) to send a literal semicolon. `#3 north` repeats `north` three times.
- History: `Up`/`Down` prefix-match; `Ctrl+R` fuzzy search. Survives `/reload`. `!`/`!!`/`!prefix` expand. Configurable via `rune.config.set("history_character", "!" | "^" | "" | ...)`.
- `Ctrl+E` opens `$EDITOR`. CRLF and the trailing final LF are normalized; everything else (indentation, tabs, blank lines) is preserved.
- Tab completion cycles words seen in server output (and your own input), most-recent-first. Requires at least two typed characters; skips words shorter than three. `Shift+Tab` goes backward. Choices are shown in the status bar.
- `Ctrl+W` / `Alt+Backspace` delete word. `Alt+Left`/`Alt+Right` / `Ctrl+Left`/`Ctrl+Right` move by word. `Home`/`End` move the input cursor.

For multiline blocks: `Alt+V` toggles command/verbatim mode; `Ctrl+Enter` / `Ctrl+J` inserts a newline (enters the composer). Verbatim sends each physical line without command processing. A submission is capped at 1,000 physical lines / 256 KiB — larger drafts are rejected with a warning.

`rune.config` (set in `init.lua`, applied atomically on `/reload`):

| Key                 | Type                | Default | Meaning                                          |
|---------------------|---------------------|---------|--------------------------------------------------|
| `command_separator` | non-empty string    | `";"`   | Text that separates multiple commands            |
| `history_character` | one visible char or `""` | `"!"` | History-expansion character; `""` disables it    |
| `keep_input`        | bool                | false   | Leave typed text selected for repeat             |
| `numpad`            | bool                | false   | Enable physical-numpad bindings                  |
| `mouse`             | bool                | false   | Capture mouse for wheel scrolling                |

---

## 17. Clipboard

`rune.clipboard.set(text)` uses OSC 52 — the terminal does the work, so it works over SSH with no remote clipboard tool. Kitty, Alacritty, WezTerm, iTerm2, Windows Terminal, foot are supported; some cap the per-copy size. tmux needs `set-clipboard on` or `external`. No `get` — most terminals refuse OSC 52 reads (a server reading your clipboard is a security problem).

---

## 18. Patterns and recipes

The cookbook has full worked examples. Distilled here for use as templates.

### 18.1 Quake-style chat console

```lua
rune.bind("`", function() rune.pane.toggle("chat") end)

local style = rune.style
local function mirror(tag, color, name, msg)
    rune.pane.write("chat", color("[" .. tag .. "]") .. " " ..
        style.bold(name) .. ": " .. msg)
end

rune.trigger.regex("^(\\w+) tells you: (.+)$",
    function(m) mirror("Tell", style.cyan, m[1], m[2]) end,
    { group = "chat-console" })
rune.trigger.regex("^You tell (\\w+): (.+)$",
    function(m) mirror("Tell", style.cyan, "-> " .. m[1], m[2]) end,
    { group = "chat-console" })
rune.trigger.regex("^(\\w+) \\[(\\w+)\\]: (.+)$",
    function(m) mirror(m[2], style.yellow, m[1], m[3]) end,
    { group = "chat-console" })

rune.ui.layout({
    type = "column",
    children = {
        { type = "pane", name = "chat", size = 10, hidden = true },
        { type = "pane", name = "output", border = "none" },
        { type = "input" },
        { type = "bar", name = "status" },
    },
})
```

### 18.2 HP bar from GMCP

```lua
local vitals = {}
rune.gmcp.subscribe("Char")
rune.gmcp.on("Char.Vitals", function(data)
    vitals = data
    rune.ui.refresh_bars()      -- render now, don't wait for the 250ms tick
end)

local function blocks(cur, max, width, color)
    local filled = max > 0 and math.floor(width * cur / max + 0.5) or 0
    return color(string.rep("█", filled)) ..
        rune.style.gray(string.rep("░", width - filled))
end

rune.ui.bar("vitals", function()
    local hp, mhp = tonumber(vitals.hp), tonumber(vitals.maxhp)
    if not (hp and mhp) then return "" end
    local sp, msp = tonumber(vitals.sp) or 0, tonumber(vitals.maxsp) or 1
    local hp_color = (hp < mhp * 0.25) and rune.style.red or rune.style.green
    return string.format("HP %s %d/%d   SP %s %d/%d",
        blocks(hp, mhp, 14, hp_color), hp, mhp,
        blocks(sp, msp, 10, rune.style.cyan), sp, msp)
end)

rune.ui.layout({
    type = "column",
    children = {
        { type = "pane", name = "output", border = "none" },
        { type = "bar", name = "vitals" },
        { type = "input" },
        { type = "bar", name = "status" },
    },
})
```

Without GMCP, feed `vitals` from a prompt trigger instead:
`rune.trigger.regex("^HP:(\\d+)/(\\d+)", fn, { on = "prompt" })`. The bar code doesn't change.

### 18.3 Highlight & gag as data

```lua
local highlights = {
    { pattern = "tells you",     color = rune.style.cyan },
    { pattern = "You are hit",   color = rune.style.red },
    { pattern = "levels up!",    color = rune.style.green },
    { pattern = "The sun rises", color = rune.style.yellow },
}
for _, h in ipairs(highlights) do
    rune.trigger.contains(h.pattern, function(_, ctx)
        return h.color(ctx.line:clean())
    end, { group = "highlights" })
end

local gags = {
    "The barkeep polishes a glass",
    "A gentle breeze blows",
    "drops a piece of lint",
}
for _, g in ipairs(gags) do
    rune.trigger.contains(g, nil, { gag = true, group = "gags" })
end
-- /group gags off       ; silence gags without removing them
-- /group highlights off ; toggle highlights off
```

### 18.4 Auto-login with world bookmarks

```lua
-- Once: store per-world character
rune.world.add("viking", "vikingmud.org:2001", { character = "Ragnar" })

-- Auto-answer login
local pending
rune.hooks.on("connecting", function(addr)
    pending = nil
    for _, w in ipairs(rune.world.list()) do
        local entry = rune.world.get(w.name)
        if entry.address == addr and entry.character then
            pending = entry.character
        end
    end
end)
local function send_character()
    if pending then
        rune.send(pending)
        pending = nil  -- fire once per connection; clears so the trigger stays inert if the phrase recurs mid-session
    end
end
rune.trigger.contains("What is your name", send_character)              -- complete line
rune.trigger.contains("What is your name", send_character, { on = "prompt" })  -- partial line
```

For passwords, prefer `os.getenv("MUD_PASSWORD")` and `rune.send_raw` (skips command expansion so `;`/`#` arrive intact). Never put a password in `store.json`.

### 18.5 Forward tells to Telegram

```lua
local TOKEN = os.getenv("TELEGRAM_TOKEN") or rune.store.get("telegram_token")
local CHAT  = os.getenv("TELEGRAM_CHAT")  or rune.store.get("telegram_chat")

local function urlencode(s)
    return (s:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function telegram(text)
    if not (TOKEN and CHAT) then return end
    rune.http.post(
        "https://api.telegram.org/bot" .. TOKEN .. "/sendMessage",
        "chat_id=" .. urlencode(CHAT) .. "&text=" .. urlencode(text),
        { headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
          timeout = 10 },
        function(resp, err)
            if err then rune.echo("[telegram] " .. err)
            elseif resp.status ~= 200 then rune.echo("[telegram] HTTP " .. resp.status)
            end
        end)
end

rune.trigger.regex("^(\\w+) tells you: (.+)$", function(m)
    telegram(m[1] .. ": " .. m[2])
end, { name = "tells-to-telegram", group = "telegram" })
```

**Secrets:** the environment variable is the better home for the token, since `store.json` is plaintext on disk. The `rune.store` fallback is a convenience — use it knowing the trade-off.

Arm when idle:

```lua
local idle
rune.hooks.on("input", function()
    rune.group.disable("telegram")
    if idle then idle:remove() end
    idle = rune.timer.after(300, function() rune.group.enable("telegram") end)
end, { priority = 10 })
```

### 18.6 Spellup / mode toggle

```lua
rune.bind("f2", function()
    if rune.group.is_enabled("spellup") then
        rune.group.disable("spellup")
    else
        rune.group.enable("spellup")
    end
    rune.ui.refresh_bars()
end)
```

### 18.7 Combat alias pack (group-toggleable)

```lua
rune.alias.exact("n", "sneak north", { group = "sneaky" })
rune.alias.exact("s", "sneak south", { group = "sneaky" })
-- /group sneaky off ; back to plain direction commands
```

### 18.8 Highlighting a single word

```lua
rune.trigger.contains("gold coins", function(_, ctx)
    return ctx.line:clean():gsub("gold coins",
        rune.style.yellow("gold coins"))
end)
```

### 18.9 Gag-and-count (silence spam, keep data)

```lua
local swings = 0
rune.trigger.contains("You swing at", function()
    swings = swings + 1
    rune.ui.refresh_bars()
    return false  -- gag
end, { group = "gags" })

rune.ui.bar("swings", function() return "swings: " .. swings end)

rune.ui.layout({
    type = "column",
    children = {
        { type = "pane", name = "output", border = "none" },
        { type = "bar", name = "swings" },
        { type = "input" },
        { type = "bar", name = "status" },
    },
})
```

---

## 19. Common mistakes to avoid

1. **Lua patterns in regex.** Rune uses Go RE2. `\\d`, `\\w`, `\\s` work. Lua's `%d`/`%w`/`%s` do not. Backslashes need to be doubled in Lua string literals.
2. **Source attribution is by `file:line` at registration time.** Every registration records the `file:line` where it was registered. Top-level calls in `init.lua` or `require()`d files give clean attribution; calls inside functions record whatever line that `rune.trigger.contains(...)` etc. appears on, which may not be where you think. `/aliases`, `/triggers`, etc. show the source line for every registration.
3. **Bindings that swallow printable keys.** A printable bind only fires when input is empty/fully-selected, which is correct — don't try to work around it. To make a chord fire even with text typed, use a non-printable modifier like `ctrl+j` or `f1`.
4. **Disabling a bind when you meant `unbind`.** Disabling consumes the key (no fallthrough). `unbind` restores normal behavior.
5. **Putting secrets in `store.json`.** It's plaintext. Use `os.getenv` or the system keychain.
6. **Timer + `/reload`.** Timers don't survive reload — recreate them in `init.lua`.
7. **`gmcp-hello` not firing.** If you replace `gmcp-hello` with a no-op, your server gets no `Core.Hello` and may bail. Either keep it or send your own.
8. **Pane buffer created, no placement.** `rune.pane.write("chat", ...)` auto-creates the buffer but the layout tree must also contain `{ type = "pane", name = "chat" }` (or have it hidden via `hidden = true`) for the user to see it.
9. **Re-registering the same alias.exact phrase.** Allowed — replaces. But re-registering with `opts.name` on `alias.exact` is ignored with a notice; the phrase is already the name.
10. **Asking triggers to rewrite multi-line spans.** Spans have already been displayed when the action fires. Return values are ignored. Use `gag = true` to hide.
11. **Fighting ANSI codes.** Triggers match the clean line. Use `ctx.line:raw()` to re-emit styled text, `ctx.line:clean()` to match or rewrite.
12. **Throwing handlers.** A handler that throws is skipped for that line and reported once; it cannot abort the chain. Three consecutive failures trigger quarantine. Keep callbacks safe — assume any line might arrive at any time.
13. **Forgetting `rune.config.set(...)` belongs in `init.lua`.** Direct property assignment isn't supported. Use `get`/`set`.

---

## 20. Snippet cookbook — copy-paste building blocks

### 20.1 HP at-a-glance bar without GMCP

```lua
local pct
rune.trigger.regex("^HP:%s*(\\d+)/(\\d+)", function(m)
    pct = tonumber(m[1]) / tonumber(m[2])
    rune.ui.refresh_bars()
end, { on = "prompt", name = "hp-prompt" })

rune.ui.bar("hp", function()
    if not pct then return "" end
    local color = pct < 0.25 and rune.style.red
              or pct < 0.50 and rune.style.yellow
              or rune.style.green
    return color(string.format("HP %d%%", math.floor(pct * 100 + 0.5)))
end)
```

### 20.2 Auto-loot on corpse

```lua
-- Default to true; rune.store.get returns nil for missing keys
local autoloot = rune.store.get("autoloot")
if autoloot == nil then autoloot = true end

rune.trigger.regex("^The corpse of .* contains:", function()
    rune.send("get all from corpse")
end, { name = "autoloot" })

rune.trigger.contains("You are hit", function()
    if autoloot then
        rune.send("get all from corpse")
    end
end)
```

### 20.3 Repeat-last-target

```lua
local last_target
rune.alias.regex("^kk (\\w+)$", function(m)
    last_target = m[1]
    rune.send("kill " .. last_target)
end)
rune.alias.exact("again", function()
    if last_target then rune.send("kill " .. last_target) end
end)
```

### 20.4 Status form for the group pane

```lua
rune.gmcp.on("Group", function(g)
    local lines = { "Group: " .. g.groupname .. "  Leader: " .. g.leader }
    for _, m in ipairs(g.members) do
        lines[#lines + 1] = string.format("%-12s %6d/%-6d",
            m.name, m.info.hp, m.info.mhp)
    end
    rune.pane.replace("group", table.concat(lines, "\n"))
end)
```

### 20.5 Chat-channel highlight

```lua
local channels = { ["ooc"] = rune.style.cyan, ["newbie"] = rune.style.green }
rune.trigger.regex("^(\\w+) \\[(\\w+)\\]: (.+)$", function(m)
    local color = channels[m[2]:lower()] or rune.style.gray
    return color(m[1]) .. rune.style.gray(" [" .. m[2] .. "]: ") .. m[3]
end, { group = "chat-style" })
```

### 20.6 Auto-save timer

```lua
rune.timer.every(60, "save", { name = "autosave" })
```

### 20.7 AFK auto-responder

```lua
local afk = false
rune.alias.exact("afk", function() afk = true; rune.echo("AFK on") end)
rune.alias.exact("back", function() afk = false; rune.echo("AFK off") end)
rune.trigger.regex("^(\\w+) tells you: (.+)$", function(m)
    if afk then
        rune.send("tell " .. m[1] .. " BRB, afk")
    end
end)
```

### 20.8 Pick your target with a picker

```lua
rune.bind("ctrl+x", function()
    rune.ui.picker.show({
        title = "Target",
        items = { "rat", "goblin", "orc", "troll" },
        on_select = function(v) rune.send("kill " .. v) end,
    })
end)
```

### 20.9 Custom command with subcommands

```lua
rune.command.add("pather", function(args)
    local sub, rest = args:match("^(%S*)%s*(.*)$")
    if sub == "go" then
        -- pather.go(rest)
    elseif sub == "stop" then
        -- pather.stop()
    else
        rune.echo("[Usage] /pather go <place> | /pather stop")
    end
end, "Walk saved paths")
```

### 20.10 Override the default `>` echo prefix

```lua
rune.hooks.on("echo", function(text)
    return rune.style.cyan("» " .. text)
end, { priority = 50 })  -- before the default 100
```

### 20.11 Replace default scroll key instead of dropping it

```lua
local scroll = assert(rune.binds.get("pgup")):action()
rune.bind("pgup", function()
    scroll()
    rune.echo(rune.style.gray("[scrolled]"))
end)
```

---

## 21. Recipes for common tasks (task → API)

| Task                                                | API                                                                |
|-----------------------------------------------------|--------------------------------------------------------------------|
| Save typing                                         | `rune.alias.exact` / `rune.alias.regex`                            |
| React to a server line                              | `rune.trigger.contains` / `starts` / `exact` / `regex`             |
| Capture and decide                                  | `rune.trigger.regex` with a function action                        |
| Highlight text                                      | Trigger function returning a styled string                         |
| Gag noise                                           | `rune.trigger.contains(text, nil, { gag = true })`                 |
| Multi-line block (chat, score)                      | `rune.trigger.regex(..., { span = { ... } })`                      |
| Login/partial-line trigger                          | `{ on = "prompt" }`                                                |
| One-shot retrials                                   | `rune.timer.every` with `ctx:remove()`                             |
| Delayed sequence                                    | `rune.timer.after` chain                                           |
| Auto-log every session                              | `rune.hooks.on("connected", ...)` + `rune.log.start`               |
| Mirror chat to a pane                               | Trigger writes to `rune.pane.write`, returns nil                   |
| Move chat out of main output                        | Trigger writes to pane, returns `false`                            |
| Vitals from GMCP                                    | `rune.gmcp.on` → store → `rune.ui.bar` + `refresh_bars`            |
| Toggle a UI element                                 | Key bind + `rune.pane.toggle` / `rune.ui.regions.toggle`           |
| Cycle a game mode                                   | Group + key bind + `rune.group.enable/disable` + `refresh_bars`    |
| Send to many lines at once                          | Function action + `for ... rune.send(...)`                         |
| Send multiple physical lines without interpretation | `rune.send_raw("a\nb")` or input hook returning `false`            |
| Persistent settings                                 | `rune.store.set`                                                   |
| World bookmarks                                     | `rune.world.add` / `/world add`                                    |
| Per-character data per world                        | `rune.world.add(name, addr, { character = "..." })`                |
| Auto-login                                          | `connecting` hook + prompt/complete-line triggers                  |
| Auto-login password                                 | `os.getenv` + `rune.send_raw`                                      |
| Search scrollback                                   | `rune.ui.search` / `Ctrl+F`                                        |
| Fuzzy history                                       | `Ctrl+R`                                                           |
| Send a webhook                                      | `rune.http.post` with a callback                                  |
| Copy text to OS clipboard                           | `rune.clipboard.set`                                               |
| Compose in editor                                   | `rune.input.open_editor` / `Ctrl+E`                                |
| Repeat last command                                 | `!` (default) / `rune.config.set("history_character", ...)`        |
| Custom verb on the input line                       | `rune.command.add`                                                 |
| Persistent counter                                  | `rune.session.set/get` (survive reload) or `rune.store` (disk)     |
| Multi-line blocks sent as-is                        | `rune.send_raw("a\nb\nc")` or paste in verbatim mode               |

---

## 22. Reference index (runemud.com)

- [Installation](https://runemud.com/getting-started/installation/) — binary, config dir, `--config-dir`.
- [Your First Session](https://runemud.com/getting-started/first-session/) — connect, bookmarks, navigation.
- [Scripting Basics](https://runemud.com/getting-started/scripting-basics/) — `init.lua`, edit/reload, split into files.
- [Migrating](https://runemud.com/getting-started/migrating/) — TinTin++, Mudlet, MUSHclient translation tables.
- [The Scripting Model](https://runemud.com/scripting/model/) — names, options, context, handles, groups, quarantine. **Read once.**
- [Triggers](https://runemud.com/scripting/triggers/) / [Aliases](https://runemud.com/scripting/aliases/) / [Timers](https://runemud.com/scripting/timers/) / [Hooks](https://runemud.com/scripting/hooks/) / [Keybindings](https://runemud.com/scripting/keybindings/) / [Slash Commands](https://runemud.com/scripting/commands/) / [Groups](https://runemud.com/scripting/groups/) / [GMCP](https://runemud.com/scripting/gmcp/) / [Storage](https://runemud.com/scripting/storage/) / [Logging](https://runemud.com/scripting/logging/) — per-feature guides.
- [Layout](https://runemud.com/interface/layout/) / [Bars](https://runemud.com/interface/bars/) / [Panes](https://runemud.com/interface/panes/) / [Pickers](https://runemud.com/interface/pickers/) / [Input](https://runemud.com/interface/input/) — UI guides.
- [Cookbook](https://runemud.com/cookbook/) — quake-console, telegram, hp-bar, highlights, autologin.
- [Lua API Overview](https://runemud.com/reference/api/) — namespaces, handles, names, options, management, quarantine.
- Per-namespace API references: [Core](https://runemud.com/reference/api/core/), [State & Lines](https://runemud.com/reference/api/state-lines/), [style](https://runemud.com/reference/api/style/), [regex](https://runemud.com/reference/api/regex/), [trigger](https://runemud.com/reference/api/trigger/), [alias](https://runemud.com/reference/api/alias/), [timer](https://runemud.com/reference/api/timer/), [hooks](https://runemud.com/reference/api/hooks/), [bind](https://runemud.com/reference/api/bind/), [command](https://runemud.com/reference/api/command/), [group](https://runemud.com/reference/api/group/), [gmcp](https://runemud.com/reference/api/gmcp/), [http](https://runemud.com/reference/api/http/), [input](https://runemud.com/reference/api/input/), [storage](https://runemud.com/reference/api/storage/), [log](https://runemud.com/reference/api/log/), [ui](https://runemud.com/reference/api/ui/), [picker](https://runemud.com/reference/api/picker/), [pane](https://runemud.com/reference/api/pane/), [clipboard](https://runemud.com/reference/api/clipboard/).
- [Slash Commands](https://runemud.com/reference/slash-commands/) — built-in `/` commands.
- [Protocols](https://runemud.com/reference/protocols/) — telnet options, GMCP, MCCP2, TLS.

---

## 23. Quick reference card

```
rune.send(text)                  -- command syntax + aliases, then send
rune.send_raw(text)              -- bypass command processing; newlines OK
rune.echo(text)                  -- local display only
rune.connect("host:port" | "tls://host:port")
rune.disconnect()
rune.reload() / rune.load(path) / rune.quit()
rune.config_dir, rune.version, rune.debug, rune.dbg(msg)
rune.config.get/set(key, value)

rune.state: connected, address, scroll_mode, scroll_lines, search_active, width, height
rune.line.new(text).raw() / :clean()

rune.style.red|green|yellow|blue|magenta|cyan|white|gray
rune.style.bold|dim|inverse

rune.regex.match(pattern, text)   -- captures only; nil on no match
rune.regex.compile(pattern):match(text)  -- full match at [1], captures from [2]
rune.regex.validate(pattern)

rune.trigger.exact|starts|contains|regex(pat, action, opts)
  opts: group, priority, once, name, gag, raw, on="output"|"prompt", span={to,raw,max}
  action: string (sends; %N capture substitution in regex)
         | function(matches|args, ctx) returning nil | string | false

rune.alias.exact(phrase, action, opts)         -- args appended to string
rune.alias.regex(pattern, action, opts)        -- %N from captures

rune.timer.after|every(seconds, action, opts)
  action: string | function(ctx); ctx:remove() cancels

rune.hooks.on(event, handler, opts)
  data: input(text, ctx), output(line), prompt(line, confirmed), echo(text)
  notification: ready, connecting, connected, disconnecting, disconnected,
               reloading, reloaded, loaded, error, input_changed,
               window_size_changed, gmcp, gmcp_enabled

rune.bind(key, function, opts) / rune.unbind(key)
rune.command.add(name, handler, description?, opts?)  -- /handler; args is string
rune.group.enable|disable|is_enabled(name); .list()

rune.gmcp.subscribe|unsubscribe|on|send|send_raw|is_enabled|list
rune.http.get(url, opts?, callback?) / .post(url, body, opts?, callback?)
  callback(response, err) — exactly one set; response.status/body/headers
rune.input.get|set|get_cursor|set_cursor|open_editor|word_left|word_right|delete_word
rune.history.get|add

rune.session.set|get|delete (strings only)
rune.store.set|get|delete (JSON-able values)
rune.world.add|get|remove|list

rune.log.start|stop|status|write
rune.clipboard.set

rune.ui.layout({ type, children, size, min_size, max_size, gap, dividers, hidden, id, title, border, char })
rune.ui.bar(name, function(width), opts) -- return string | {left,center,right} | nil
rune.ui.refresh_bars()
rune.ui.search({ query = "..." })
rune.ui.regions.show|hide|toggle|is_hidden(id)
rune.ui.picker.show({ title, items, on_select, mode, match_description, dismiss_on_space })

rune.pane.create|write|replace|show|hide|toggle|is_hidden|clear
rune.pane.scroll_up|scroll_down(name, lines?)        -- 1 line by default
rune.pane.scroll_to_top|scroll_to_bottom(name)

-- Registry management (each namespace):
rune.<reg>.list() / .count() / .clear() / .remove_group(g)
rune.<reg>.get(name) / .enable(name) / .disable(name) / .remove(name)

-- Slash commands:
/connect, /disconnect, /reconnect, /world add|remove|list, /worlds
/load, /reload, /lua, /test
/aliases, /triggers, /timers, /hooks, /binds, /bars, /commands, /groups, /gmcp
/group <name> on|off
/log start|stop|status, /raw, /echo, /version, /quit, /help
/find [pattern]   -- scrollback search (also Ctrl+F)
```
