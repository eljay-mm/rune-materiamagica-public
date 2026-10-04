-- updater.lua -- pull the latest config from the public repo, no git needed.
--
--   /update         fetch, apply, and reload
--   /update check   report whether a newer version exists
--
-- Compares the installed commit (rune.store "updater.sha") with the latest on
-- the public GitHub repo, then re-downloads only the files whose git blob SHA
-- changed (tracked in rune.store "updater.files"). Pure rune.http + rune.json,
-- so it behaves the same on Linux, macOS, and Windows.
--
-- Synced: every *.lua, cook/recipes.json, mapper/spdr.json.
-- Never touched: mapper/map.db (your map), store.json, position.txt, docs.

local REPO = "horstgs/rune-materiamagica-public"
local BRANCH = "main"
local API = "https://api.github.com/repos/" .. REPO
local RAW = "https://raw.githubusercontent.com/" .. REPO
local UA = "rune-materiamagica-updater"

local API_OPTS = { headers = { ["User-Agent"] = UA, ["Accept"] = "application/vnd.github+json" }, timeout = 30 }
local RAW_OPTS = { headers = { ["User-Agent"] = UA }, timeout = 30 }

local DIR = rune.config_dir or "."

local function short(sha) return (tostring(sha or "")):sub(1, 7) end
local function local_path(path) return DIR .. "/" .. path end

local function should_sync(path)
    if path:sub(-4) == ".lua" then return true end
    if path == "cook/recipes.json" then return true end
    if path == "mapper/spdr.json" then return true end
    return false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

-- Write beside the target then swap it in, so a failed write never truncates
-- the file that is currently in use. os.remove first keeps the rename working
-- on Windows, where renaming over an existing file can fail.
local function write_replace(dest, text)
    local tmp = dest .. ".utmp"
    local f = io.open(tmp, "wb")
    if not f then return false, "cannot write " .. tmp end
    f:write(text)
    f:close()
    os.remove(dest)
    local ok, err = os.rename(tmp, dest)
    if not ok then
        os.remove(tmp)
        return false, tostring(err)
    end
    return true
end

-- HTTP ----------------------------------------------------------------------

local function fetch_latest(cb)
    rune.http.get(API .. "/commits/" .. BRANCH, API_OPTS, function(resp, err)
        if err then return cb(nil, err) end
        if not resp or resp.status ~= 200 then
            return cb(nil, "HTTP " .. tostring(resp and resp.status))
        end
        local ok, data, derr = pcall(rune.json.decode, resp.body)
        if not ok or derr or type(data) ~= "table" or type(data.sha) ~= "string" then
            return cb(nil, "bad commit response")
        end
        cb(data.sha)
    end)
end

local function fetch_tree(sha, cb)
    rune.http.get(API .. "/git/trees/" .. sha .. "?recursive=1", API_OPTS, function(resp, err)
        if err then return cb(nil, err) end
        if not resp or resp.status ~= 200 then
            return cb(nil, "HTTP " .. tostring(resp and resp.status))
        end
        local ok, data, derr = pcall(rune.json.decode, resp.body)
        if not ok or derr or type(data) ~= "table" or type(data.tree) ~= "table" then
            return cb(nil, "bad tree response")
        end
        cb(data.tree)
    end)
end

-- Change detection ----------------------------------------------------------

-- For a fresh tree, work out which synced files changed (blob SHA differs from
-- what we installed) and which we installed but are now gone upstream.
local function plan(tree)
    local target = {}
    for _, e in ipairs(tree) do
        if type(e) == "table" and e.type == "blob" and should_sync(e.path) then
            target[e.path] = { sha = e.sha, size = tonumber(e.size) }
        end
    end
    local installed = rune.store.get("updater.files")
    if type(installed) ~= "table" then installed = {} end
    local files, changed, removed = {}, {}, {}
    for p, meta in pairs(target) do
        files[p] = meta.sha
        if installed[p] ~= meta.sha then changed[#changed + 1] = p end
    end
    for p in pairs(installed) do
        if should_sync(p) and target[p] == nil then removed[#removed + 1] = p end
    end
    table.sort(changed)
    table.sort(removed)
    return target, files, changed, removed
end

local function rollback(state)
    for _, b in ipairs(state.backups) do
        if b.old == nil then
            os.remove(b.path)
        else
            local f = io.open(b.path, "w")
            if f then
                f:write(b.old)
                f:close()
            end
        end
        os.remove(b.path .. ".utmp")
    end
end

local function download(target, sha, list, i, state, cb)
    if i > #list then return cb() end
    local path = list[i]
    rune.http.get(RAW .. "/" .. sha .. "/" .. path, RAW_OPTS, function(resp, err)
        if err then return cb(path .. ": " .. err) end
        if not resp or resp.status ~= 200 then
            return cb(path .. ": HTTP " .. tostring(resp and resp.status))
        end
        local want = target[path] and target[path].size
        if want and #resp.body ~= want then
            return cb(path .. ": size mismatch (" .. #resp.body .. " vs " .. want .. ")")
        end
        local dest = local_path(path)
        state.backups[#state.backups + 1] = { path = dest, old = read_file(dest) }
        local ok, werr = write_replace(dest, resp.body)
        if not ok then return cb(path .. ": " .. tostring(werr)) end
        download(target, sha, list, i + 1, state, cb)
    end)
end

-- Commands ------------------------------------------------------------------

local function do_check()
    fetch_latest(function(sha, err)
        if err then
            rune.echo("[update] check failed: " .. tostring(err))
            return
        end
        if sha == rune.store.get("updater.sha") then
            rune.echo("[update] up to date (" .. short(sha) .. ")")
        else
            rune.echo("[update] update available (" .. short(sha) .. ") - run /update")
        end
    end)
end

local function do_update()
    if rune.session.get("updater.busy") then
        rune.echo("[update] already running")
        return
    end
    rune.session.set("updater.busy", "1")
    local function finish(msg)
        rune.session.delete("updater.busy")
        if msg then rune.echo(msg) end
    end

    fetch_latest(function(sha, err)
        if err then return finish("[update] check failed: " .. tostring(err)) end
        if sha == rune.store.get("updater.sha") then
            return finish("[update] already up to date (" .. short(sha) .. ")")
        end
        fetch_tree(sha, function(tree, terr)
            if terr then return finish("[update] tree failed: " .. tostring(terr)) end
            local target, files, changed, removed = plan(tree)
            if #changed == 0 and #removed == 0 then
                rune.store.set("updater.sha", sha)
                rune.store.set("updater.files", files)
                return finish("[update] already up to date (" .. short(sha) .. ")")
            end
            rune.echo(string.format("[update] %s: %d changed, %d removed",
                short(sha), #changed, #removed))
            local state = { backups = {} }
            download(target, sha, changed, 1, state, function(derr)
                if derr then
                    rollback(state)
                    return finish("[update] failed: " .. tostring(derr) .. " (rolled back)")
                end
                for _, p in ipairs(removed) do os.remove(local_path(p)) end
                rune.store.set("updater.sha", sha)
                rune.store.set("updater.files", files)
                finish("[update] updated to " .. short(sha) .. " - reloading")
                rune.reload()
            end)
        end)
    end)
end

rune.command.add("update", function(args)
    local sub = (args or ""):match("^%s*(%S*)") or ""
    if sub == "check" then do_check() else do_update() end
end, "Update this config from the public repo (or '/update check')")

-- Startup notice ------------------------------------------------------------
-- One quiet line when a newer version exists. Session-guarded (not on every
-- /reload) and silent on any network error or first-ever run.

rune.hooks.on("ready", function()
    if rune.session.get("updater.notified") then return end
    rune.session.set("updater.notified", "1")
    local installed = rune.store.get("updater.sha")
    if not installed then return end          -- never updated yet: no nag
    fetch_latest(function(sha, err)
        if err or not sha or sha == installed then return end
        rune.echo(rune.style.yellow("[update]") ..
            " a newer config is available (" .. short(sha) .. ") - type /update")
    end)
end, { name = "updater-notice" })
