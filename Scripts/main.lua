--[[
    KaisSilentAssasin

    A guard only calls in a pager if it is aware of a heister when it dies.

    Stock behaviour: killing any guard arms a pager, whether or not the guard
    ever saw you. This mod ties the pager to the guard's awareness AT THE TIME
    OF DEATH:

        never noticed anything            ->  no pager
        was suspicious, then lost you     ->  no pager   (configurable)
        suspicious right now              ->  stock pager
        fully detected you at any point   ->  stock pager, permanently

    Full detection is always a one-way latch: once a guard has actually
    identified a heister it can page even if it later calms down. Whether
    partial suspicion behaves the same way is set by ResetOnSuspicionLost in
    config.ini - see that file, which the mod writes itself on first run.

    How it works: the game arms the pager in native code, with no event to
    intercept, so instead of blocking the call this decides in advance whether
    each guard is CAPABLE of paging, and flips that as its awareness changes:

        guard spawns                      -> pager marked snatched (cannot page)
        suspicion above threshold         -> unmark (can page)
        suspicion back below threshold    -> mark again (cannot page)
        full detection                    -> unmark for good

    bIsPagerSnatched is the game's own native "this guard has no pager" state,
    the one behind the snatch-the-pager mechanic - not an invented flag.

    Entirely event driven. No polling loop; the only enumeration is a single
    sweep when a heist starts, to catch guards that spawned before the hooks.

    NOTE: pager arming is server side. This works solo and when hosting. As a
    client in someone else's lobby the host decides, and these local flags
    will not stop it.
--]]

-- Not a config option: this is a crash-risk lever, not a gameplay setting.
-- Set true only if bIsPagerSnatched ever stops suppressing the pager.
local ALSO_CLEAR_PAGER_DATA = false

local AI_CLASS    = "/Script/Starbreeze.SBZAICharacter"
local ALERTED     = AI_CLASS .. ":Multicast_ShowAlertedMarker"
local SUSPICIOUS  = AI_CLASS .. ":Multicast_UpdateSuspiciousMarkers"
local SUSP_SINGLE = AI_CLASS .. ":Multicast_UpdateSuspiciousMarkerProgress"
local SUSP_HIDE   = AI_CLASS .. ":Multicast_HideSuspiciousMarker"
local RESTART     = "/Script/Engine.PlayerController:ClientRestart"

-- Paths are relative to the process working directory, which is the folder
-- holding the game exe (Binaries\Win64) - not the UE4SS folder. If the mod
-- folder cannot be written to, both the config and the log fall back to the
-- working directory.
local MOD_DIR         = "UE4SS/Mods/KaisSilentAssasin"
local CONFIG_PRIMARY  = MOD_DIR .. "/config.ini"
local CONFIG_FALLBACK = "KaisSilentAssasin.ini"
local LOG_NAME        = "KaisSilentAssasin.log"

-- Resolved at config load time to sit beside whichever config was used.
local log_path = LOG_NAME

-- ---------------------------------------------------------------- config --

local DEFAULT_CONFIG_TEXT = [[
; KaisSilentAssasin configuration
;
; Re-read at every heist start, so edits take effect on the next heist -
; no need to restart the game. Unknown keys and unparseable values are
; ignored, fall back to the default, and are reported in the log.

; What happens to a guard who got suspicious but never fully detected you,
; and has since lost interest.
;   true  = he is a silent kill again (his pager is taken back)
;   false = HARDCORE: any suspicion above the threshold, ever, lets him
;           page for the rest of the heist
; Full detection always latches permanently, regardless of this setting.
ResetOnSuspicionLost = true

; How much suspicion progress (0.0 - 1.0) counts as "he saw me".
; The game emits progress updates constantly, including tiny flickers far
; below 0.001, and at 0.0 every one of those counts.
; Raise it to ignore brief glances, e.g. 0.25.
SuspicionThreshold = 0.0

; Write this mod's own log file (KaisSilentAssasin.log, in this same folder).
; Off by default; turn it on to check what the mod did in a heist.
LogToFile = false

; Also write the same lines to UE4SS.log / the UE4SS console.
; That file is wiped by UE4SS on every game launch.
LogToUE4SSLog = false

; Start each heist with a fresh KaisSilentAssasin.log.
; false = append across heists, which lets the file grow without bound.
TruncateLogOnHeistStart = true

; How many pagers you may answer per heist, before the next one starts the
; search.
;
; NOTE: only LOWERING works. The cap itself cannot be written - it lives in a
; struct inside a fixed array, and UE4SS writes land in a cached copy that the
; game never reads. So this spends answers instead. Asking for more than the
; heist grants is reported in the log and ignored.
;
; Every heist grants its own number, taken from the game rather than guessed.
; The log line "live max N" is what this heist allows - on Bebe it is 2. The
; game state's own MaxAnswerCount field is NOT that number and is ignored; it
; read 4 on a heist whose real maximum was 2.
;
; The cap is applied at heist start, as soon as the HUD first draws, and the
; radio counter on the HUD is corrected to match: it counts down from your
; number instead of the heist's. In the game's own convention the counter
; reads 1 when the NEXT answer starts the search. If the HUD hooks ever fail
; to register in time, the cap lands at the first answered pager instead and
; the log says so; the enforcement is exact either way.
;
;   -1 = leave the game's own value alone (default)
;    0 = HARDCORE: the first pager you answer starts the search
;    1 = one pager answered safely, the second starts the search
;    2 = two answered safely, and so on
;
; Host side only, like the rest of this mod.
MaxPagerAnswers = -1
]]

-- Keys are stored lowercase for case-insensitive lookup.
local DEFAULTS = {
    resetonsuspicionlost    = true,
    suspicionthreshold      = 0.0,
    logtofile               = false,
    logtoue4sslog           = false,
    truncatelogonheiststart = true,
    maxpageranswers         = -1,
}

-- Pretty names for log messages.
local KEY_NAMES = {
    resetonsuspicionlost    = "ResetOnSuspicionLost",
    suspicionthreshold      = "SuspicionThreshold",
    logtofile               = "LogToFile",
    logtoue4sslog           = "LogToUE4SSLog",
    truncatelogonheiststart = "TruncateLogOnHeistStart",
    maxpageranswers         = "MaxPagerAnswers",
}

-- Per-key validation for numeric settings. One shared 0.0-1.0 range would be
-- wrong now that not every number is a probability.
local NUMERIC_RANGES = {
    suspicionthreshold = { min = 0.0, max =  1.0, integer = false },
    maxpageranswers    = { min =  -1, max = 20.0, integer = true  },
}

local cfg = {}
for k, v in pairs(DEFAULTS) do cfg[k] = v end

local config_path = nil       -- whichever file was actually read
local pending_notes = {}      -- parse messages, emitted once logging is configured

local function note(fmt, ...)
    pending_notes[#pending_notes + 1] = string.format(fmt, ...)
end

local function parse_bool(s)
    s = s:lower()
    if s == "true"  or s == "1" or s == "yes" or s == "on"  then return true  end
    if s == "false" or s == "0" or s == "no"  or s == "off" then return false end
    return nil
end

local function read_file(path)
    local ok, f = pcall(io.open, path, "r")
    if not ok or not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function write_file(path, text)
    local ok, f = pcall(io.open, path, "w")
    if not ok or not f then return false end
    f:write(text)
    f:close()
    return true
end

local function apply_line(line)
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if not key then
        note("ignored unparseable config line: %s", line)
        return
    end

    local lkey = key:lower()
    local default = DEFAULTS[lkey]
    if default == nil then
        note("unknown config key '%s' ignored", key)
        return
    end

    if type(default) == "boolean" then
        local b = parse_bool(value)
        if b == nil then
            note("%s: '%s' is not true/false, using default %s", key, value, tostring(default))
        else
            cfg[lkey] = b
        end
    else
        local n = tonumber(value)
        local r = NUMERIC_RANGES[lkey]
        if n == nil then
            note("%s: '%s' is not a number, using default %s", key, value, tostring(default))
        elseif r and (n < r.min or n > r.max) then
            note("%s: %s is outside %g-%g, using default %s",
                 key, value, r.min, r.max, tostring(default))
        elseif r and r.integer and n ~= math.floor(n) then
            note("%s: %s must be a whole number, using default %s",
                 key, value, tostring(default))
        else
            cfg[lkey] = n
        end
    end
end

-- Keep the log beside the config that was actually used. Verified by an
-- append test, so an unwritable mod folder falls back instead of silently
-- dropping every log line.
local function resolve_log_path()
    local candidate = LOG_NAME
    if config_path then
        local dir = config_path:match("^(.*)[/\\][^/\\]+$")
        if dir then candidate = dir .. "/" .. LOG_NAME end
    end

    if candidate ~= LOG_NAME then
        local ok, f = pcall(io.open, candidate, "a")
        if ok and f then
            f:close()
        else
            note("cannot write %s, logging to %s instead", candidate, LOG_NAME)
            candidate = LOG_NAME
        end
    end

    log_path = candidate
end

local function load_config()
    pending_notes = {}
    for k, v in pairs(DEFAULTS) do cfg[k] = v end

    local text = read_file(CONFIG_PRIMARY)
    if text then
        config_path = CONFIG_PRIMARY
    else
        text = read_file(CONFIG_FALLBACK)
        if text then
            config_path = CONFIG_FALLBACK
        end
    end

    if not text then
        -- First run: write a self-documenting default so every option is
        -- discoverable from the file itself.
        if write_file(CONFIG_PRIMARY, DEFAULT_CONFIG_TEXT) then
            config_path = CONFIG_PRIMARY
            note("no config found, wrote defaults to %s", CONFIG_PRIMARY)
        elseif write_file(CONFIG_FALLBACK, DEFAULT_CONFIG_TEXT) then
            config_path = CONFIG_FALLBACK
            note("no config found, wrote defaults to %s", CONFIG_FALLBACK)
        else
            config_path = nil
            note("no config found and could not create one - using built-in defaults")
        end
        resolve_log_path()
        return
    end

    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^[;#]") then
            apply_line(trimmed)
        end
    end

    resolve_log_path()
end

-- ------------------------------------------------------------------- log --

local guards = {}   -- name -> { silenced, fullyDetected, wasSnatched, pagerData }
local stats = { silenced = 0, restored = 0, resilenced = 0 }
local header_line = nil
local header_pending = false   -- true between a level load and the first guard

local function log(fmt, ...)
    local line = string.format(fmt, ...)
    if cfg.logtoue4sslog then
        print("[KaisSilentAssasin] " .. line .. "\n")
    end
    if cfg.logtofile then
        local ok, f = pcall(io.open, log_path,"a")
        if ok and f then
            f:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), line))
            f:close()
        end
    end
end

local function truncate_log()
    if not (cfg.logtofile and cfg.truncatelogonheiststart) then return end
    local ok, f = pcall(io.open, log_path,"w")
    if ok and f then
        if header_line then
            f:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), header_line))
        end
        f:close()
    end
end

local function log_config()
    log("config: %s", config_path or "built-in defaults")
    log("log:    %s", log_path)
    log("  %s = %s", KEY_NAMES.resetonsuspicionlost,    tostring(cfg.resetonsuspicionlost))
    log("  %s = %g", KEY_NAMES.suspicionthreshold,      cfg.suspicionthreshold)
    log("  %s = %s", KEY_NAMES.logtofile,               tostring(cfg.logtofile))
    log("  %s = %s", KEY_NAMES.logtoue4sslog,           tostring(cfg.logtoue4sslog))
    log("  %s = %s", KEY_NAMES.truncatelogonheiststart, tostring(cfg.truncatelogonheiststart))
    log("  %s = %d%s", KEY_NAMES.maxpageranswers, cfg.maxpageranswers,
        cfg.maxpageranswers < 0 and " (game default)" or "")
    for _, n in ipairs(pending_notes) do log("  ! %s", n) end
end

-- ---------------------------------------------------------------- guards --

local function short(name)
    return (name:match("([^.]+)$")) or name
end

local function get(obj, prop)
    local ok, v = pcall(function() return obj[prop] end)
    if ok then return v end
    return nil
end

local function set(obj, prop, value)
    return pcall(function() obj[prop] = value end)
end

local function name_of(ai)
    if not ai or not ai:IsValid() then return nil end
    local ok, n = pcall(function() return ai:GetFullName() end)
    if ok then return n end
    return nil
end

-- A guard can page only if it owns a PagerData asset. Civilians do not.
local function can_page(ai)
    local ok, valid = pcall(function() return ai.PagerData:IsValid() end)
    return ok and valid == true
end

-- Take away this guard's pager. No-op if already taken, or if the guard is
-- latched as having seen a heister.
local function silence(ai, reason)
    local name = name_of(ai)
    if not name then return end

    local g = guards[name]
    if not g then
        if not can_page(ai) then return end
        g = { silenced = false, fullyDetected = false, wasSnatched = get(ai, "bIsPagerSnatched") }
        guards[name] = g
    end

    if g.fullyDetected or g.silenced then return end

    if not set(ai, "bIsPagerSnatched", true) then
        log("could not set bIsPagerSnatched on %s - leaving it stock", short(name))
        return
    end
    if ALSO_CLEAR_PAGER_DATA then
        g.pagerData = get(ai, "PagerData")
        set(ai, "PagerData", nil)
    end

    g.silenced = true
    if reason == "spawn" then
        stats.silenced = stats.silenced + 1
    else
        stats.resilenced = stats.resilenced + 1
        log("re-silenced %s - %s (no pager again)", short(name), reason)
    end
end

-- Give the pager back. `permanent` latches it so it is never taken away again.
local function restore(ai, reason, permanent)
    local name = name_of(ai)
    if not name then return end

    local g = guards[name]
    if not g then
        -- Never tracked: still latch, so a later sweep cannot silence a guard
        -- that has already seen a heister.
        if permanent and can_page(ai) then
            guards[name] = { silenced = false, fullyDetected = true,
                             wasSnatched = get(ai, "bIsPagerSnatched") }
        end
        return
    end

    if permanent then g.fullyDetected = true end
    if not g.silenced then return end

    set(ai, "bIsPagerSnatched", g.wasSnatched == true)
    if g.pagerData ~= nil then
        set(ai, "PagerData", g.pagerData)
        g.pagerData = nil
    end

    g.silenced = false
    stats.restored = stats.restored + 1
    log("restored %s - %s%s", short(name), reason, permanent and " [permanent]" or "")
end

-- Suspicion above the threshold means "he saw me"; at or below means unaware.
-- Whether crossing it latches is the ResetOnSuspicionLost setting.
local function on_suspicion(ai, progress)
    if progress > cfg.suspicionthreshold then
        restore(ai, string.format("suspicion %g", progress), not cfg.resetonsuspicionlost)
    else
        silence(ai, string.format("suspicion %g at or below threshold", progress))
    end
end

-- ------------------------------------------------------------ pager cap --

-- Per-heist state, keyed on the game state OBJECT. A game state we have not
-- seen before means a new heist: everything here resets and the log header
-- is re-armed. Keying on the object rather than on ClientRestart matters
-- twice over: guards and the HUD both exist BEFORE ClientRestart fires at
-- level start, and if ClientRestart ever fires mid-heist (it is a pawn
-- possession event) the cap must not be charged a second time.
local heist = { key = nil, max = nil, cap_done = false, cap_applied = false }

-- MaxAnswerCount from PagerHeistDataArray is NOT the live maximum. Measured
-- in game on Bebe: element 0 reads 4 while the game passes InPagerMax = 2 to
-- the HUD. It is a fixed array of 4 (probably per difficulty) and only element
-- 0 is reachable from Lua, so it is logged as a curiosity and nothing else.
-- Writing it is impossible anyway: UE4SS hands out a cached COPY of the struct,
-- so a write reports success, a re-read returns the new value, and the game
-- keeps using the old one. Do not reintroduce that route.
local function read_stale_max(gs)
    local ok, v = pcall(function() return gs.PagerHeistDataArray.MaxAnswerCount end)
    if ok and v ~= nil then return v end
    return nil
end

local function live_game_state()
    local gs = nil
    pcall(function() gs = FindFirstOf("PD3HeistGameState") end)
    if not gs or not gs:IsValid() then return nil end
    local n = ""
    pcall(function() n = gs:GetFullName() end)
    -- On the main menu FindFirstOf hands back the class default object;
    -- writing to that template changes nothing.
    if n:find("Default__", 1, true) then return nil end
    return gs
end

-- The live game state, resetting the per-heist state if it is one we have
-- not seen before. Every entry point goes through here.
local function current_heist()
    local gs = live_game_state()
    if not gs then return nil end
    local key = ""
    pcall(function() key = gs:GetFullName() end)
    if key ~= heist.key then
        heist = { key = key, max = nil, cap_done = false, cap_applied = false }
        guards = {}
        stats.silenced, stats.restored, stats.resilenced = 0, 0, 0
        header_pending = true   -- whoever comes first writes the header
        load_config()
    end
    return gs
end

local reconcile_hud   -- defined in the pager HUD section below

-- The live maximum, as the game tells its HUD. Sources, all of which fire at
-- heist start now that the widget hooks are registered before the HUD's
-- first draw: GetPagerStatus and OnAnswerPagerValueChanged on the widget,
-- the first label text (stock draw is max+1 with nothing answered), and the
-- widget's RemainingPagers. The game state's own field is NOT it (above).
local function learn_max(v, src)
    if type(v) ~= "number" or v < 1 then return end
    if heist.max == v then return end
    if heist.max then
        log("MaxPagerAnswers: live max changed %d -> %d (%s)", heist.max, v, src)
    else
        log("MaxPagerAnswers: live max %d (%s)", v, src)
    end
    heist.max = v
    if heist.cap_applied then reconcile_hud("max learned") end
end

-- The real model, measured in game:
--     RemainingPagers = InPagerMax - AnswerPagerCount
--     the HUD displays RemainingPagers + 1
--     the search fires when you answer while RemainingPagers is already 0
-- So the answers you may safely make are InPagerMax - AnswerPagerCount, and
-- leaving exactly `want` of them means AnswerPagerCount = InPagerMax - want.
--
-- With `n` answers already made when the cap lands, setting
--
--     AnswerPagerCount = live_max - want + n
--
-- makes answer number want+1 the one that trips the search, counting from the
-- start of the heist. Normally n = 0, because the maximum is known before the
-- first pager can be answered; the term only matters if the HUD hooks failed
-- to register in time. It can never refund, since the result is always >= n.
--
-- Enough to exceed any conceivable maximum without risking a uint8 overflow
-- when the game increments it. Used only for MaxPagerAnswers = 0, which does
-- not need to know the real maximum.
local HARD_SPEND = 250

local function apply_pager_cap()
    if heist.cap_done then return end

    local want = math.floor(cfg.maxpageranswers)
    if want < 0 then
        heist.cap_done = true   -- -1: leave the game alone
        return
    end

    local gs = current_heist()
    if not gs or heist.cap_done then return end   -- retried from the next hook

    -- want == 0 needs no maximum: push the count past any of them, so the very
    -- first answer is already over the limit.
    if want == 0 then
        heist.cap_done = true
        local answered = get(gs, "AnswerPagerCount")
        if not set(gs, "AnswerPagerCount", HARD_SPEND) then
            log("MaxPagerAnswers: AnswerPagerCount is not writable - cap unchanged")
            return
        end
        heist.cap_applied = true
        heist.prespent = HARD_SPEND - (type(answered) == "number" and answered or 0)
        log("MaxPagerAnswers: 0 wanted - AnswerPagerCount %s -> %s, so the first "
            .. "pager answered starts the search", tostring(answered),
            tostring(get(gs, "AnswerPagerCount")))
        reconcile_hud("cap applied")
        return
    end

    if not heist.max then return end   -- retried once a source reports it

    heist.cap_done = true

    local answered = get(gs, "AnswerPagerCount")
    if type(answered) ~= "number" then answered = 0 end
    log("MaxPagerAnswers: live max %d, AnswerPagerCount=%d (PagerHeistDataArray "
        .. "element 0 reads %s and is ignored)",
        heist.max, answered, tostring(read_stale_max(gs)))

    if want > heist.max then
        log("MaxPagerAnswers: cannot RAISE the cap this way - this heist grants %d, "
            .. "wanted %d; left at the game default", heist.max, want)
        return
    end

    local charge = heist.max - want + answered
    if not set(gs, "AnswerPagerCount", charge) then
        log("MaxPagerAnswers: AnswerPagerCount is not writable - cap unchanged")
        return
    end

    local now = get(gs, "AnswerPagerCount")
    if now == charge then
        heist.cap_applied = true
        heist.prespent = charge - answered
        log("MaxPagerAnswers: AnswerPagerCount %d -> %d, so answer number %d "
            .. "starts the search%s", answered, charge, want + 1,
            answered > 0 and string.format(" (%d already made)", answered) or "")
        reconcile_hud("cap applied")
    else
        log("MaxPagerAnswers: AnswerPagerCount write did not hold (wanted %d, reads %s) "
            .. "- cap unchanged", charge, tostring(now))
    end
end

-- ------------------------------------------------------------ pager HUD --
--
-- Measured in game (probe runs, 2026-09-08):
--   * the counter is a URichTextBlock named RadiosLeft_Text, written by the
--     widget's event graph through the NATIVE /Script/UMG.RichTextBlock:SetText
--     with text like  <DefaultValue>3</> radios until Search  - the style tag
--     changes to WarningValue / AlertValue as the count drops;
--   * it shows (InPagerMax - AnswerPagerCount) + 1: when it reads 1, the next
--     answer starts the search;
--   * there are TWO live copies of the widget, one per heist-state screen
--     (WBP_HeistStates_Casing and _Search), and the game updates both;
--   * hooks on native UFunctions fire for calls made from Blueprint code, and
--     unlike hooks on Blueprint functions they run BEFORE and AFTER the call.
--
-- So the label is corrected by letting the game draw, then re-setting only the
-- digit from the live count. Nothing in the widget's own event graph is called
-- - calling its UpdatePagerStatus is what caused the redraw ping-pong of the
-- earlier attempt. Colour, animation and state stay the game's own.
--
-- Only active once the cap has been applied this heist; with -1, or when the
-- cap could not be applied, the HUD is never touched.

local WIDGET_CLASS = "WBP_UI_PagerWidget_C"
local WIDGET_PATH  = "/Game/UI/Widgets/HUD/PlayerAndParty/WBP_UI_PagerWidget.WBP_UI_PagerWidget_C"
local RICH_SETTEXT = "/Script/UMG.RichTextBlock:SetText"

local in_our_write = false   -- our own SetText must not re-enter the hook

local function is_valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-- Live instances only. FindFirstOf(WIDGET_CLASS) returns a template whose
-- RadiosLeft_Text is null and whose RemainingPagers is always 0 - that
-- template is what made the maximum look undiscoverable before.
local function live_widgets()
    local out = {}
    local all = nil
    pcall(function() all = FindAllOf(WIDGET_CLASS) end)
    if not all then return out end
    for _, w in pairs(all) do
        if is_valid(w) and not (name_of(w) or ""):find("Default__", 1, true) then
            local label = get(w, "RadiosLeft_Text")
            if is_valid(label) then out[#out + 1] = { widget = w, label = label } end
        end
    end
    return out
end

local function label_text(label)
    local s = nil
    pcall(function() s = label:GetText():ToString() end)
    return s
end

-- Instance names carry "WBP_UI_PagerWidget" without the "_C":
-- "...WBP_HeistStates_Casing.WidgetTree_1.WBP_UI_PagerWidget.WidgetTree_2.RadiosLeft_Text"
local function is_pager_label(name)
    return name:find("WBP_UI_PagerWidget", 1, true) ~= nil and name:sub(-15) == "RadiosLeft_Text"
end

local function screen_of(name)
    return name:match("(WBP_HeistStates_%w+)") or "pager widget"
end

-- The style tag the game wraps the digit in. The three names are the widget's
-- own Default / Warning / Alert text properties. Observed with a maximum of
-- 2: two remaining draws DefaultValue, one remaining WarningValue; none
-- remaining is AlertValue by elimination (not yet seen drawn by the game).
local function style_for(remaining)
    if remaining <= 0 then return "AlertValue" end
    if remaining == 1 then return "WarningValue" end
    return "DefaultValue"
end

-- What the label should show, in the game's own convention: with `r` safe
-- answers left the digit is r + 1, coloured for r, and it reaches 0 on the
-- answer that starts the search (the game draws 0 there too). The player's
-- own answers are AnswerPagerCount minus what the cap pre-spent, so this
-- needs no maximum - which is what makes it exact for MaxPagerAnswers = 0.
local function hud_target()
    if not (heist.cap_applied and heist.prespent) then return nil end
    local gs = live_game_state()
    if not gs then return nil end
    local answered = get(gs, "AnswerPagerCount")
    if type(answered) ~= "number" then return nil end
    local mine = answered - heist.prespent
    local digit = math.floor(cfg.maxpageranswers) - mine + 1
    if digit < 0 then digit = 0 end
    return digit, style_for(digit - 1)
end

-- Re-set one label if its digit or colour is off. The whole "<Tag>digit</>"
-- token is replaced when the text has that shape, otherwise just the digit.
-- Text without a digit (Search, Alarm) is left alone.
local function fix_label(label, raw, why)
    local want, style = hud_target()
    if not want then return end
    local tag, digit_s = raw:match("<(%w+)>(%d+)</>")
    local digit = tonumber(digit_s or raw:match("%d+") or "")
    if not digit then return end
    if digit == want and (tag == nil or tag == style) then return end

    local fixed
    if tag then
        fixed = raw:gsub("<%w+>%d+</>", "<" .. style .. ">" .. want .. "</>", 1)
    else
        fixed = raw:gsub("%d+", tostring(want), 1)
    end

    in_our_write = true
    local ok = pcall(function() label:SetText(FText(fixed)) end)
    in_our_write = false
    local screen = screen_of(name_of(label) or "")
    if ok then
        log("HUD: %s radios %d -> %d, %s -> %s (%s)", screen, digit, want,
            tostring(tag), tag and style or "n/a", why)
    else
        log("HUD: could not write %s (%s)", screen, why)
    end
end

-- Every live label, right now. Used when the count moves without the game
-- redrawing: the cap being applied, or the maximum becoming known after it.
reconcile_hud = function(why)
    for _, e in ipairs(live_widgets()) do
        local raw = label_text(e.label)
        if raw then fix_label(e.label, raw, why) end
    end
end

-- --------------------------------------------------------- widget hooks --
--
-- The HUD is driven by the Blueprint widget WBP_UI_PagerWidget_C, which
-- overrides the native PD3HUDPagerWidget events - so the /Script/ versions
-- never fire; the Blueprint's own functions are hooked instead. Hooks on
-- non-/Script/ paths fire AFTER the function and cannot alter it, which is
-- fine: they are only sources for the maximum, plus a trace.
--
-- The Blueprint class must already be loaded when these are registered, so
-- registration is retried from every heist entry point until it succeeds.
-- The first guard spawn comes before the HUD's first draw, and that is what
-- makes the maximum available at heist start.

local UPDATE_FN = ":UpdatePagerStatus"
local STATUS_FN = ":GetPagerStatus"
local ANSWER_FN = ":OnAnswerPagerValueChanged"

local update_hooked = false

local function hook_update(path)
    if update_hooked then return true end

    local ok_u = pcall(function()
        RegisterHook(path .. UPDATE_FN, function(Context, InPagerCount, InPagerMax)
            local count, max = nil, nil
            pcall(function() count = InPagerCount:get() end)
            pcall(function() max = InPagerMax:get() end)
            local g = live_game_state()
            log("trace: UpdatePagerStatus InPagerCount=%s InPagerMax=%s | AnswerPagerCount=%s",
                tostring(count), tostring(max), g and tostring(get(g, "AnswerPagerCount")) or "?")
            learn_max(max, "UpdatePagerStatus")
            apply_pager_cap()
        end)
    end)
    local ok_s = pcall(function()
        RegisterHook(path .. STATUS_FN, function(Context, InPagerMax)
            local max = nil
            pcall(function() max = InPagerMax:get() end)
            learn_max(max, "GetPagerStatus")
            apply_pager_cap()
        end)
    end)
    local ok_a = pcall(function()
        RegisterHook(path .. ANSWER_FN, function(Context, AnswerPagerValue, MaxAnswerPagerValue)
            local max = nil
            pcall(function() max = MaxAnswerPagerValue:get() end)
            learn_max(max, "OnAnswerPagerValueChanged")
            apply_pager_cap()
        end)
    end)

    if ok_u or ok_s or ok_a then
        update_hooked = true
        log("trace: hooked %s%s=%s %s=%s %s=%s", path, UPDATE_FN, tostring(ok_u),
            STATUS_FN, tostring(ok_s), ANSWER_FN, tostring(ok_a))
    end
    return update_hooked
end

-- NOT a source for the maximum: the widget's own RemainingPagers. The HUD
-- lives under the game instance, not the level, so a widget may carry the
-- previous heist's value into the next one and produce a wrong cap.

-- Guards spawned before the hooks were live (heist start). One sweep, not a loop.
local function sweep(reason)
    local all = FindAllOf("SBZAICharacter")
    if not all then return end
    local before = stats.silenced
    for _, ai in pairs(all) do
        silence(ai, "spawn")
    end
    -- Silent on the main menu, where this finds nothing and the log has not
    -- been truncated for a new heist yet.
    if stats.silenced > before or not header_pending then
        log("sweep on %s: silenced %d more (total %d)", reason, stats.silenced - before, stats.silenced)
    end
end

-- Per-heist housekeeping, from whichever entry point comes first: the log
-- header (after the truncation, so nothing it logs is wiped), the widget
-- hooks, and the sweep. Returns the live game state, or nil on the main menu.
local function heist_housekeeping(reason)
    local gs = current_heist()
    if not gs then return nil end
    if header_pending then
        header_pending = false
        truncate_log()
        log("--- heist start (%s) ---", reason)
        log_config()
        sweep("heist start")
    end
    hook_update(WIDGET_PATH)
    return gs
end

-- ----------------------------------------------------------------- hooks --

-- New guards as they stream in during the heist. Also the retry point for the
-- pager cap: guards only spawn once the heist game state exists, so by the
-- first spawn the write is guaranteed to have something real to write to.
NotifyOnNewObject(AI_CLASS, function(ai)
    ExecuteInGameThread(function()
        if heist_housekeeping("guard spawn") then
            apply_pager_cap()
        end
        silence(ai, "spawn")
    end)
end)

-- The HUD counter. Native function, so it can be hooked at load and runs both
-- before and after the game's write. Before: the first draw of a heist is
-- max+1 with nothing answered, a source for the maximum that needs no
-- Blueprint hook at all. After: put the corrected digit back.
local ok_hud = pcall(function()
    RegisterHook(RICH_SETTEXT, function(Context, InText)
        if in_our_write then return end
        local name = name_of(Context:get()) or ""
        if not is_pager_label(name) then return end
        local gs = heist_housekeeping("HUD draw")
        if not gs then return end
        if not heist.max and get(gs, "AnswerPagerCount") == 0 then
            local raw = ""
            pcall(function() raw = InText:get():ToString() end)
            local d = tonumber(raw:match("%d+") or "")
            if d and d >= 2 then learn_max(d - 1, "first HUD draw") end
        end
    end, function(Context, InText)
        if in_our_write then return end
        local label = Context:get()
        if not is_pager_label(name_of(label) or "") then return end
        apply_pager_cap()
        local raw = label_text(label)
        if raw then fix_label(label, raw, "game redraw") end
    end)
end)

-- Full detection: always permanent.
local ok_alert = pcall(function()
    RegisterHook(ALERTED, function(Context, DetectedActor)
        local who = "detected a heister"
        pcall(function() who = "detected " .. short(DetectedActor:get():GetFullName()) end)
        restore(Context:get(), who, true)
    end)
end)

-- Suspicion meter, array form (one entry per player being watched).
local ok_susp = pcall(function()
    RegisterHook(SUSPICIOUS, function(Context, DetectedPlayers)
        local best = 0.0
        pcall(function()
            DetectedPlayers:get():ForEach(function(_, elem)
                local p = elem:get().Progress or 0.0
                if p > best then best = p end
            end)
        end)
        on_suspicion(Context:get(), best)
    end)
end)

-- Suspicion meter, single-value form.
local ok_single = pcall(function()
    RegisterHook(SUSP_SINGLE, function(Context, Progress)
        local p = 0.0
        pcall(function() p = Progress:get() or 0.0 end)
        on_suspicion(Context:get(), p)
    end)
end)

-- Suspicion ended outright.
local ok_hide = pcall(function()
    RegisterHook(SUSP_HIDE, function(Context)
        silence(Context:get(), "suspicion marker hidden")
    end)
end)

-- Level start. Also fires on the main menu (no live game state: nothing
-- happens) and possibly mid-heist (same game state: nothing resets). Only a
-- heist that somehow produced neither a guard spawn nor a HUD draw yet gets
-- its housekeeping from here.
local ok_restart = pcall(function()
    RegisterHook(RESTART, function()
        heist_housekeeping("ClientRestart")
    end)
end)

-- ------------------------------------------------------------------ init --

load_config()

header_line = string.format(
    "loaded (hooks: alerted=%s suspicion=%s suspicionSingle=%s suspicionHide=%s restart=%s hud=%s, clearPagerData=%s)",
    tostring(ok_alert), tostring(ok_susp), tostring(ok_single), tostring(ok_hide),
    tostring(ok_restart), tostring(ok_hud), tostring(ALSO_CLEAR_PAGER_DATA))

-- Normally fails here - the widget class is not loaded on the main menu - and
-- succeeds from the first heist entry point instead.
hook_update(WIDGET_PATH)

log("%s", header_line)
log_config()
