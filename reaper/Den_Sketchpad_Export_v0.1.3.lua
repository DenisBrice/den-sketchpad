-- @description Den Sketchpad Export v0.1.3
-- @author Denis + Claude
-- @about
--   Sends the current REAPER song to Den Sketchpad on the iPad.
--   Copies every audio item (original files, no FX, no MIDI/instruments) with its position, trim,
--   fades and gain, plus track names, colours, volume, pan and mute, and packs them as a .sketch.zip
--   in Dropbox/REAPER/_SKETCHES. Whole song, or only the time selection if there is one.
--   On the iPad: Sketchpad > PROJECT > OPEN A SKETCH ZIP, pick it from Files > Dropbox.
--   Selected tracks are exported; with none selected, every track that has audio items.

local SCRIPT = "Den Sketchpad Export v0.1.3"
local r = reaper
local SEP = package.config:sub(1, 1)
local IS_WIN = SEP == "\\"

local function msg(m) r.ShowMessageBox(m, SCRIPT, 0) end
local function q(p) return '"' .. p .. '"' end
local function exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end

-- JSON writer
local function jstr(s)
  s = tostring(s):gsub('[%c"\\]', function(c)
    local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return m[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end
local function json(v, ind)
  ind = ind or ""
  local t = type(v)
  if t == "table" then
    local n = #v
    local parts = {}
    if v.__array and n == 0 then return "[]" end
    if n > 0 then
      for i = 1, n do parts[#parts + 1] = json(v[i], ind .. " ") end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do if k ~= "__array" then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = jstr(k) .. ":" .. json(v[k], ind .. " ") end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then return jstr(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    if math.type and math.type(v) == "integer" then return tostring(v) end
    return string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", ".0")
  elseif t == "boolean" then return v and "true" or "false"
  else return "null" end
end

local function sketches_dir()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local dir = src:match("^(.*)[/\\]_REAPER_SCRIPTS[/\\]")
  if dir then return dir .. SEP .. "_SKETCHES" end
  return r.GetProjectPath("") .. SEP .. "_SKETCHES"
end

local function hex_of(track)
  local c = r.GetTrackColor(track)
  if c == 0 then return nil end
  local R, G, B = r.ColorFromNative(c)
  return string.format("#%02x%02x%02x", R, G, B)
end

local function lin2db(v) if not v or v <= 0.000001 then return -60 end return 20 * math.log(v, 10) end

local function copy_file(a, b)
  local fi = io.open(a, "rb") if not fi then return false end
  local fo = io.open(b, "wb") if not fo then fi:close() return false end
  while true do local d = fi:read(1048576) if not d then break end fo:write(d) end
  fi:close() fo:close() return true
end

-- WAV reading: only the part of a file an item uses is sent, so long takes stay small
local wavCache = {}
local function wav_info(fn)
  if wavCache[fn] ~= nil then return wavCache[fn] end
  local info = false
  local f = io.open(fn, "rb")
  if f then
    local hdr = f:read(12)
    if hdr and #hdr == 12 and hdr:sub(1, 4) == "RIFF" and hdr:sub(9, 12) == "WAVE" then
      local fmt
      while true do
        local ch = f:read(8)
        if not ch or #ch < 8 then break end
        local id, sz = ch:sub(1, 4), string.unpack("<I4", ch, 5)
        if id == "fmt " then
          local d = f:read(sz)
          local tag, nch, sr, _, align, bits = string.unpack("<I2I2I4I4I2I2", d)
          if tag == 0xFFFE and sz >= 26 then tag = string.unpack("<I2", d, 25) end
          fmt = { tag = tag, ch = nch, sr = sr, align = align, bits = bits }
          if sz % 2 == 1 then f:read(1) end
        elseif id == "data" then
          if fmt and (fmt.tag == 1 or fmt.tag == 3) and fmt.align > 0 then
            fmt.dataOff = f:seek()
            local total = f:seek("end")
            fmt.dataLen = math.min(sz, total - fmt.dataOff) -- also copes with a 0 / huge size from unfinished files
            if sz == 0 or sz == 0xFFFFFFFF then fmt.dataLen = total - fmt.dataOff end
            info = fmt
          end
          break
        else
          f:seek("cur", sz + (sz % 2))
        end
      end
    end
    f:close()
  end
  wavCache[fn] = info
  return info
end

local function wav_extract(fn, info, t0, t1, dst)
  local f = io.open(fn, "rb") if not f then return false end
  local o = io.open(dst, "wb") if not o then f:close() return false end
  local frames = math.max(0, math.floor((t1 - t0) * info.sr + 0.5))
  local first = math.max(0, math.floor(t0 * info.sr + 0.5))
  local maxFrames = math.floor(info.dataLen / info.align)
  if first + frames > maxFrames then frames = math.max(0, maxFrames - first) end
  local bytes = frames * info.align
  o:write("RIFF", string.pack("<I4", 36 + bytes), "WAVE", "fmt ", string.pack("<I4I2I2I4I4I2I2", 16, info.tag, info.ch, info.sr, info.sr * info.align, info.align, info.bits),
    "data", string.pack("<I4", bytes))
  f:seek("set", info.dataOff + first * info.align)
  local left = bytes
  while left > 0 do
    local d = f:read(math.min(left, 1048576))
    if not d then break end
    o:write(d) left = left - #d
  end
  f:close() o:close()
  return true
end

-- the real audio file behind a take (follows section / reverse wrappers)
local function take_file(take)
  local src = r.GetMediaItemTake_Source(take)
  local secOffs, rev = 0, false
  if r.PCM_Source_GetSectionInfo then
    local ok, o, _, rv = r.PCM_Source_GetSectionInfo(src)
    if ok then secOffs = o or 0; rev = rv and true or false end
  end
  local s = src
  for _ = 1, 4 do
    local fn = r.GetMediaSourceFileName(s, "")
    if fn and fn ~= "" then return fn, s, rev, secOffs end
    local parent = r.GetMediaSourceParent(s)
    if not parent then break end
    s = parent
  end
  return nil
end

local OK_EXT = { wav = true, aif = true, aiff = true, mp3 = true, m4a = true, caf = true, flac = true, wave = true }

local function main()
  local proj = 0
  local nTr = r.CountTracks(proj)
  if nTr == 0 then msg("No tracks in this project.") return end

  local ts, te = r.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  local useSel = te - ts > 0.5
  local rs, re
  if useSel then rs, re = ts, te else rs, re = 0, r.GetProjectLength(proj) end
  if re - rs < 0.5 then msg("The song is empty.") return end

  local selCount = r.CountSelectedTracks(proj)
  if selCount > 0 and selCount < nTr then
    local a = r.ShowMessageBox(selCount .. " track" .. (selCount == 1 and " is" or "s are") .. " selected.\n\nYES = send only the selected track" .. (selCount == 1 and "" or "s") .. "\nNO = send all tracks", SCRIPT, 3)
    if a == 2 then return end
    if a == 7 then selCount = 0 end
  end
  local plan, files, fileOrder = {}, {}, {}
  local skipped = { midi = 0, other = 0, rate = 0, muted = 0 }
  local totalBytes = 0

  for i = 0, nTr - 1 do
    local tr = r.GetTrack(proj, i)
    if selCount == 0 or r.IsTrackSelected(tr) then
      local _, name = r.GetTrackName(tr)
      local t = { name = name, color = hex_of(tr),
        vol = math.max(-60, math.floor(lin2db(r.GetMediaTrackInfo_Value(tr, "D_VOL")) * 10 + 0.5) / 10),
        pan = math.floor(r.GetMediaTrackInfo_Value(tr, "D_PAN") * 100 + 0.5),
        mute = r.GetMediaTrackInfo_Value(tr, "B_MUTE") == 1, solo = false, input = "1", items = {} }
      for k = 0, r.CountTrackMediaItems(tr) - 1 do
        local it = r.GetTrackMediaItem(tr, k)
        local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
        local take = r.GetActiveTake(it)
        if take and pos < re and pos + len > rs and r.GetMediaItemInfo_Value(it, "B_MUTE") ~= 0 then skipped.muted = skipped.muted + 1
        elseif take and pos < re and pos + len > rs then
          if r.TakeIsMIDI(take) then skipped.midi = skipped.midi + 1
          else
            local fn, src, rev, secOffs = take_file(take)
            local ext = fn and fn:match("%.([%w]+)$")
            if not fn or not ext or not OK_EXT[ext:lower()] or not exists(fn) then skipped.other = skipped.other + 1
            elseif math.abs(r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") - 1) > 0.0001 or rev then skipped.rate = skipped.rate + 1
            else
              local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") + (secOffs or 0)
              -- crop to the export range
              local cut0 = math.max(0, rs - pos)
              local cut1 = math.max(0, pos + len - re)
              local fin = r.GetMediaItemInfo_Value(it, "D_FADEINLEN")
              local fout = r.GetMediaItemInfo_Value(it, "D_FADEOUTLEN")
              local nlen = len - cut0 - cut1
              local _, tname = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
              local gain = lin2db(r.GetMediaItemInfo_Value(it, "D_VOL") * math.abs(r.GetMediaItemTakeInfo_Value(take, "D_VOL")))
              local base = fn:match("([^/\\]+)%.[%w]+$") or "audio"
              local winfo = ext:lower():match("^wave?$") and wav_info(fn)
              local clipId, rel, clipOffs
              if winfo then
                -- just the slice this item plays
                local t0 = offs + cut0
                local key = fn .. "|" .. string.format("%.4f|%.4f", t0, nlen)
                if not files[key] then
                  local id = "c" .. (#fileOrder + 1)
                  files[key] = { id = id, ext = "wav", name = base, src = fn, info = winfo, t0 = t0, t1 = t0 + nlen,
                    sr = winfo.sr, ch = winfo.ch, len = nlen }
                  fileOrder[#fileOrder + 1] = key
                  totalBytes = totalBytes + nlen * winfo.sr * winfo.align
                end
                clipId, clipOffs = files[key].id, 0
              else
                if not files[fn] then
                  local id = "f" .. (#fileOrder + 1)
                  local fsz = 0
                  local fh = io.open(fn, "rb") if fh then fsz = fh:seek("end") fh:close() end
                  totalBytes = totalBytes + fsz
                  files[fn] = { id = id, ext = ext:lower(), name = base, src = fn,
                    sr = r.GetMediaSourceSampleRate(src), ch = r.GetMediaSourceNumChannels(src), len = (r.GetMediaSourceLength(src)) }
                  fileOrder[#fileOrder + 1] = fn
                end
                clipId, clipOffs = files[fn].id, offs + cut0
              end
              local f = files[winfo and (fn .. "|" .. string.format("%.4f|%.4f", offs + cut0, nlen)) or fn]
              t.items[#t.items + 1] = { name = tname ~= "" and tname or base, clip = clipId, file = "audio/" .. clipId .. "." .. f.ext,
                pos = pos + cut0 - rs, len = nlen, offs = clipOffs,
                fadeIn = cut0 > 0 and 0 or math.min(fin, nlen), fadeOut = cut1 > 0 and 0 or math.min(fout, nlen),
                gain = math.max(-24, math.min(24, math.floor(gain * 10 + 0.5) / 10)) }
            end
          end
        end
      end
      if #t.items > 0 or selCount > 0 then plan[#plan + 1] = t end
    end
  end

  -- whole song: start at the bar of the first item, so a song that sits an hour into the
  -- project does not open an hour into the iPad timeline
  local startBar = 1
  do
    local mn, mx = math.huge, 0
    for _, t in ipairs(plan) do for _, it in ipairs(t.items) do
      mn = math.min(mn, it.pos); mx = math.max(mx, it.pos + it.len) end end
    if mn < math.huge then
      local old = rs                      -- item positions are relative to old
      local _, measures = r.TimeMap2_timeToBeats(proj, mn + old)
      local barStart = r.TimeMap2_beatsToTime(proj, 0, measures)
      if not barStart or barStart > mn + old then barStart = mn + old end
      if barStart < old then barStart = old end
      local shift = barStart - old
      for _, t in ipairs(plan) do for _, it in ipairs(t.items) do it.pos = it.pos - shift end end
      rs, re = barStart, math.min(re, mx + old)
      startBar = (measures or 0) + 1
    end
  end

  local nItems = 0
  for _, t in ipairs(plan) do nItems = nItems + #t.items end
  if nItems == 0 then
    msg("No audio items to send" .. (skipped.midi > 0 and (" (" .. skipped.midi .. " MIDI items are left out).") or "."))
    return
  end

  local mb = totalBytes / 1048576
  local notes = {}
  if skipped.midi > 0 then notes[#notes + 1] = skipped.midi .. " MIDI item(s) left out" end
  if skipped.rate > 0 then notes[#notes + 1] = skipped.rate .. " stretched or reversed item(s) left out" end
  if skipped.muted > 0 then notes[#notes + 1] = skipped.muted .. " muted item(s) left out" end
  if skipped.other > 0 then notes[#notes + 1] = skipped.other .. " item(s) with missing or unsupported files left out" end
  local warn = ""
  if mb > 400 then warn = "\n\nWARNING: " .. math.floor(mb) .. " MB of audio may be too much for the iPad. Select fewer tracks or set a time selection." end
  local ok = r.ShowMessageBox(string.format("Send %d item%s on %d track%s to Den Sketchpad?\n%s\nAudio files: %d (%d MB)%s%s",
    nItems, nItems == 1 and "" or "s", #plan, #plan == 1 and "" or "s",
    (useSel and "Time selection" or "Whole song") .. ", starting at bar " .. startBar .. string.format(" (%.1f min).", (re - rs) / 60), #fileOrder, math.floor(mb + 0.5),
    #notes > 0 and ("\n\n" .. table.concat(notes, "\n")) or "", warn), SCRIPT, 1)
  if ok ~= 1 then return end

  local outDir = sketches_dir()
  r.RecursiveCreateDirectory(outDir, 0)
  local _, projName = r.EnumProjects(-1)
  local base = (projName ~= "" and projName:match("([^/\\]+)%.[Rr][Pp][Pp]$")) or "Untitled"
  base = base:gsub("[^%w%-_ ]", ""):gsub("%s+", "_")
  local stamp = os.date("%Y%m%d_%H%M")
  local work = outDir .. SEP .. base .. "_" .. stamp .. "_tmp"
  r.RecursiveCreateDirectory(work .. SEP .. "audio", 0)

  local clips, copied = {}, {}
  for _, key in ipairs(fileOrder) do
    local f = files[key]
    local rel = "audio/" .. f.id .. "." .. f.ext
    local dst = work .. SEP .. "audio" .. SEP .. f.id .. "." .. f.ext
    local ok
    if f.info then ok = wav_extract(f.src, f.info, f.t0, f.t1, dst) else ok = copy_file(f.src, dst) end
    if ok then
      copied[#copied + 1] = dst
      clips[f.id] = { name = f.name, sr = f.sr, ch = f.ch, len = f.len, file = rel }
    end
  end

  local bpm = r.TimeMap_GetDividedBpmAtTime and r.TimeMap_GetDividedBpmAtTime(rs) or r.Master_GetTempo()
  local bpb = r.TimeMap_GetTimeSigAtTime(proj, rs)
  local pj = { format = "den-sketchpad", version = "0.1", name = base:gsub("_", " ") .. " (from REAPER)",
    bpm = math.floor(bpm * 100 + 0.5) / 100, bpb = bpb or 4, exported = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    cursor = 0, master = { vol = 0, limit = true }, tracks = plan, clips = clips }
  local ls, le = r.GetSet_LoopTimeRange2(proj, false, true, 0, 0, false)
  if le > ls and ls >= rs and le <= re then pj.loop = { on = false, start = ls - rs, ["end"] = le - rs }
  else pj.loop = { on = false, start = 0, ["end"] = 0 } end
  plan[#plan + 1] = { name = "New idea", color = "#2a9d8f", vol = 0, pan = 0, mute = false, solo = false, input = "1", items = { __array = true } }
  for _, t in ipairs(plan) do if #t.items == 0 then t.items = { __array = true } end end

  local fh = io.open(work .. SEP .. "project.json", "wb")
  fh:write(json(pj)) fh:close()

  local zip = outDir .. SEP .. base .. "_" .. stamp .. ".sketch.zip"
  if IS_WIN then
    r.ExecProcess('cmd.exe /C cd /d ' .. q(work) .. ' && tar -a -cf ' .. q(zip) .. ' project.json audio', 600000)
  else
    local sh = work .. SEP .. "zip.sh"
    local s = io.open(sh, "wb")
    s:write("cd " .. q(work) .. " && /usr/bin/zip -0 -r -q " .. q(zip) .. " project.json audio\n")
    s:close()
    r.ExecProcess("/bin/sh " .. q(sh), 600000)
    os.remove(sh)
  end
  if not exists(zip) then msg("Could not make the zip. The files are in:\n" .. work) return end

  for _, p in ipairs(copied) do os.remove(p) end
  os.remove(work .. SEP .. "project.json")
  os.remove(work .. SEP .. "audio")
  os.remove(work)

  msg(string.format("Done: %d items, %d audio files.\n\n%s\n\nOn the iPad: Den Sketchpad > PROJECT > OPEN A SKETCH ZIP, then Files > Dropbox > REAPER > _SKETCHES.\n(Give Dropbox a minute to upload it.)%s",
    nItems, #copied, zip, #notes > 0 and ("\n\n" .. table.concat(notes, "\n")) or ""))
end

main()
