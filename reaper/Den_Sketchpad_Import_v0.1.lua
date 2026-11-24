-- @description Den Sketchpad Import v0.1
-- @author Denis + Claude
-- @about
--   Rebuilds a Den Sketchpad (iPad) session in REAPER.
--   Pick the .sketch.zip you saved to Dropbox (or a project.json inside an unzipped sketch).
--   Makes the tracks (name, colour, volume, pan, mute, solo), puts every item back at the same
--   place with its trim, fades and gain, sets tempo / time signature and the loop.
--   The iPad FX (EQ, COMP, ECHO, HAZE) are written into the project notes and each track's
--   notes so you can rebuild them with Den plugins.

local SCRIPT = "Den Sketchpad Import v0.1"
local r = reaper
local SEP = package.config:sub(1, 1)
local IS_WIN = SEP == "\\"

---------------------------------------------------------------- tiny JSON reader
local function json_decode(s)
  local pos = 1
  local function err(m) error("project.json: " .. m .. " at char " .. pos) end
  local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
  local val
  local function str()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then err("unterminated string") end
      if c == '"' then pos = pos + 1 break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if map[e] then out[#out + 1] = map[e]; pos = pos + 2
        elseif e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or 63
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16) or 0
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00); pos = pos + 6
          end
          if utf8 and utf8.char then out[#out + 1] = utf8.char(cp) else out[#out + 1] = cp < 128 and string.char(cp) or "?" end
        else err("bad escape") end
      else
        local nxt = s:find('[\\"]', pos) or (#s + 1)
        out[#out + 1] = s:sub(pos, nxt - 1); pos = nxt
      end
    end
    return table.concat(out)
  end
  function val()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local o = {}; ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return o end
      while true do
        ws(); if s:sub(pos, pos) ~= '"' then err("expected key") end
        local k = str(); ws()
        if s:sub(pos, pos) ~= ":" then err("expected :") end
        pos = pos + 1; o[k] = val(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return o elseif d ~= "," then err("expected , or }") end
      end
    elseif c == "[" then
      pos = pos + 1; local a = {}; ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return a end
      while true do
        a[#a + 1] = val(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return a elseif d ~= "," then err("expected , or ]") end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then err("unexpected '" .. c .. "'") end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local ok, res = pcall(val)
  if not ok then return nil, res end
  return res
end

---------------------------------------------------------------- helpers
local function msg(m) r.ShowMessageBox(m, SCRIPT, 0) end
local function exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end
local function read_all(p) local f = io.open(p, "rb") if not f then return nil end local d = f:read("*a") f:close() return d end
local function dirname(p) return p:match("^(.*)[/\\]") or "." end
local function basename(p) return p:match("([^/\\]+)$") or p end
local function db2lin(db) if not db or db <= -60 then return 0 end return 10 ^ (db / 20) end
local function q(p) return '"' .. p:gsub('"', '\\"') .. '"' end
local function hexcolor(h)
  local rr, gg, bb = (h or ""):match("#?(%x%x)(%x%x)(%x%x)")
  if not rr then return 0 end
  return r.ColorToNative(tonumber(rr, 16), tonumber(gg, 16), tonumber(bb, 16)) | 0x1000000
end
local function num(v, d) if type(v) == "number" then return v end return d end

local function unzip(zip)
  local base = basename(zip):gsub("%.sketch%.zip$", ""):gsub("%.zip$", "")
  local root = dirname(zip) .. SEP .. base
  local dest, n = root, 2
  while r.file_exists(dest .. SEP .. "project.json") or r.EnumerateFiles(dest, 0) do dest = root .. "_" .. n; n = n + 1 end
  r.RecursiveCreateDirectory(dest, 0)
  local cmd
  if IS_WIN then cmd = 'cmd.exe /C tar -xf ' .. q(zip) .. ' -C ' .. q(dest)
  else cmd = '/usr/bin/unzip -o -q ' .. q(zip) .. ' -d ' .. q(dest) end
  r.ExecProcess(cmd, 120000)
  if not exists(dest .. SEP .. "project.json") then return nil, "Could not unzip " .. zip .. "\n(tried: " .. cmd .. ")" end
  return dest
end

local function fx_summary(fx)
  if type(fx) ~= "table" then return nil end
  local parts = {}
  local e = fx.eq
  if e and e.on then parts[#parts + 1] = string.format("EQ lo-cut %d Hz, low %+.1f, mid %+.1f @ %d Hz, high %+.1f", num(e.hp, 20), num(e.low, 0), num(e.mid, 0), num(e.midF, 900), num(e.high, 0)) end
  local c = fx.comp
  if c and c.on then parts[#parts + 1] = string.format("COMP squeeze %d%%, output %+.1f dB", num(c.amount, 0), num(c.make, 0)) end
  local ec = fx.echo
  local steps = { "1/16", "1/8", "1/8.", "1/4", "1/4.", "1/2" }
  if ec and ec.on then parts[#parts + 1] = string.format("ECHO %s, repeats %d%%, tone %d%%, mix %d%%", steps[math.floor(num(ec.time, 3) + 0.5) + 1] or "?", num(ec.fb, 0), num(ec.tone, 0), num(ec.mix, 0)) end
  local h = fx.haze
  if h and h.on then parts[#parts + 1] = string.format("HAZE size %.1f s, tone %d%%, motion %d%%, mix %d%%", 1.2 + num(h.size, 50) / 100 * 8.8, num(h.tone, 0), num(h.motion, 0), num(h.mix, 0)) end
  if #parts == 0 then return nil end
  return table.concat(parts, "\n")
end

---------------------------------------------------------------- main
local function main()
  local ok, path = r.GetUserFileNameForRead("", "Den Sketchpad: pick the .sketch.zip (or project.json)", "zip")
  if not ok or path == "" then return end

  local folder
  if path:lower():match("%.zip$") then
    local d, e = unzip(path)
    if not d then msg(e) return end
    folder = d
  elseif path:lower():match("%.json$") then
    folder = dirname(path)
  else
    msg("Pick a .sketch.zip or a project.json") return
  end

  local raw = read_all(folder .. SEP .. "project.json")
  if not raw then msg("No project.json in " .. folder) return end
  local pj, perr = json_decode(raw)
  if not pj then msg(perr) return end
  if pj.format ~= "den-sketchpad" then msg("This project.json is not from Den Sketchpad.") return end

  local ans = r.ShowMessageBox(
    "Sketch: " .. tostring(pj.name) .. "\n" .. #(pj.tracks or {}) .. " tracks, " .. tostring(pj.bpm) .. " bpm\n\n" ..
    "YES = open in a NEW project tab (sets tempo)\nNO = add to THIS project at the edit cursor",
    SCRIPT, 3)
  if ans == 2 then return end
  local newTab = ans == 6

  if newTab then r.Main_OnCommand(40859, 0) end -- File: New project tab
  local proj = 0
  local offset = newTab and 0 or r.GetCursorPosition()

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  if newTab and pj.bpm then
    local bpb = math.floor(num(pj.bpb, 4))
    if r.CountTempoTimeSigMarkers(proj) == 0 then
      r.SetTempoTimeSigMarker(proj, -1, 0, -1, -1, pj.bpm, bpb, 4, false)
    else
      r.SetTempoTimeSigMarker(proj, 0, 0, -1, -1, pj.bpm, bpb, 4, false)
    end
    r.UpdateTimeline()
  end

  local missing, made, items = {}, 0, 0
  local notes = { "Den Sketchpad: " .. tostring(pj.name), "Imported " .. os.date("%Y-%m-%d %H:%M") .. " from " .. folder, "" }
  local first = r.CountTracks(proj)

  for ti, t in ipairs(pj.tracks or {}) do
    local idx = r.CountTracks(proj)
    r.InsertTrackAtIndex(idx, true)
    local tr = r.GetTrack(proj, idx)
    made = made + 1
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", t.name or ("Sketch " .. ti), true)
    if t.color then r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", hexcolor(t.color)) end
    r.SetMediaTrackInfo_Value(tr, "D_VOL", db2lin(num(t.vol, 0)))
    r.SetMediaTrackInfo_Value(tr, "D_PAN", num(t.pan, 0) / 100)
    r.SetMediaTrackInfo_Value(tr, "B_MUTE", t.mute and 1 or 0)
    r.SetMediaTrackInfo_Value(tr, "I_SOLO", t.solo and 2 or 0)
    local fs = fx_summary(t.fx)
    if fs then
      notes[#notes + 1] = (t.name or ("Track " .. ti)) .. ":\n" .. fs .. "\n"
      r.GetSetMediaTrackInfo_String(tr, "P_EXT:DenSketchpadFX", fs, true)
    end
    for _, it in ipairs(t.items or {}) do
      local file = folder .. SEP .. (it.file or ""):gsub("/", SEP)
      if not exists(file) then
        missing[#missing + 1] = it.file or "?"
      else
        local item = r.AddMediaItemToTrack(tr)
        local take = r.AddTakeToMediaItem(item)
        local src = r.PCM_Source_CreateFromFile(file)
        r.SetMediaItemTake_Source(take, src)
        r.SetMediaItemInfo_Value(item, "D_POSITION", offset + num(it.pos, 0))
        r.SetMediaItemInfo_Value(item, "D_LENGTH", num(it.len, 1))
        r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", num(it.offs, 0))
        r.SetMediaItemInfo_Value(item, "D_FADEINLEN", num(it.fadeIn, 0))
        r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", num(it.fadeOut, 0))
        r.SetMediaItemInfo_Value(item, "D_VOL", db2lin(num(it.gain, 0)))
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", it.name or "sketch", true)
        items = items + 1
      end
    end
  end

  if pj.loop and pj.loop["end"] and pj.loop["end"] > (pj.loop.start or 0) then
    r.GetSet_LoopTimeRange2(proj, true, true, offset + num(pj.loop.start, 0), offset + pj.loop["end"], false)
    if pj.loop.on then r.GetSetRepeatEx(proj, 1) end
  end

  if #notes > 3 then
    notes[#notes + 1] = "Rebuild ideas: HAZE -> Den Atmosphere Clean / Den Bloom, ECHO -> Den 00 Echo, COMP -> Den 00 Comp, EQ -> Den 00 EQ."
  end
  if newTab then
    r.GetSetProjectNotes(proj, true, table.concat(notes, "\n"))
  else
    local old = r.GetSetProjectNotes(proj, false, "")
    r.GetSetProjectNotes(proj, true, (old ~= "" and (old .. "\n\n") or "") .. table.concat(notes, "\n"))
  end

  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.Undo_EndBlock("Den Sketchpad import: " .. tostring(pj.name), -1)

  local out = string.format("Imported \"%s\": %d tracks, %d items.\nAudio is in:\n%s", tostring(pj.name), made, items, folder)
  if #missing > 0 then out = out .. "\n\nMissing audio files: " .. #missing .. " (" .. missing[1] .. " ...)" end
  if #notes > 3 then out = out .. "\n\niPad FX settings are in View > Project notes." end
  if exists(folder .. SEP .. "mixdown.wav") then out = out .. "\n\nThe iPad mixdown is there too: mixdown.wav" end
  out = out .. "\n\nTip: File > Save project as... with \"Copy all media into project directory\" to keep it tidy."
  msg(out)
  local _ = first
end

main()
