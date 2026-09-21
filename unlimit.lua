-- Inventory Unlimiter V5: current ODH plugin API + durable preferences.
-- Changes CLIENT-side values only; server-side limits are not bypassed by this file.
local shared = odh_shared_plugins
if not shared or type(shared.CreateTab) ~= "function" then
    warn("[Inventory Unlimiter] Load through the current Overdrive H plugin menu.")
    return
end

local KEY = "ODH_InventoryUnlimiterRuntime"
local previous = _G[KEY]
if type(previous) == "table" and type(previous.Cleanup) == "function" then
    local ok, restored = pcall(previous.Cleanup)
    if not ok or restored == false then
        warn("[Inventory Unlimiter] Could not restore the previous instance; reload cancelled.")
        return
    end
end

local runtime = { alive=true, initializing=true, values={enabled=false, maxItems=9999}, generation=0 }
local warnings = {}
local function Notify(text, duration)
    if type(shared.Notify) == "function" then pcall(shared.Notify, text, duration or 3) end
end
local function WarnOnce(key, text)
    if warnings[key] then return end
    warnings[key] = true
    warn("[Inventory Unlimiter] " .. text)
    Notify("Inventory Unlimiter: " .. text, 5)
end
local function Finite(value)
    return type(value)=="number" and value==value and value>-math.huge and value<math.huge
end
local function ClampItems(value)
    if not Finite(value) then return nil end
    return math.clamp(math.floor(value+0.5),2,9999)
end

-- File APIs are executor-provided, not part of odh_shared_plugins.
local environment = {}
if type(getgenv)=="function" then
    local ok, result=pcall(getgenv)
    if ok and type(result)=="table" then environment=result end
end
local fileRead = type(readfile)=="function" and readfile or environment.readfile
local fileWrite = type(writefile)=="function" and writefile or environment.writefile
local fileExists = type(isfile)=="function" and isfile or environment.isfile
local FILE = "ODH_InventoryUnlimiter_settings.json"
local httpOK, HttpService = pcall(function() return game:GetService("HttpService") end)
local canPersist = type(fileRead)=="function" and type(fileWrite)=="function" and httpOK and HttpService~=nil
runtime.settingsFile=FILE
runtime.saveStatus="Not saved"

local function LoadSettings()
    if not canPersist then
        runtime.saveStatus="Unavailable"
        WarnOnce("filesystem","readfile/writefile unavailable; settings cannot survive rejoining.")
        return
    end
    if type(fileExists)=="function" then
        local ok, exists=pcall(fileExists,FILE)
        if ok and not exists then return end
    end
    local ok,text=pcall(fileRead,FILE)
    if not ok then
        if type(fileExists)=="function" then
            runtime.saveStatus="Read error"
            WarnOnce("read","Cannot read settings: " .. tostring(text))
        end
        return
    end
    local decoded,data=pcall(function() return HttpService:JSONDecode(text) end)
    if not decoded or type(data)~="table" or data.version~=1 or type(data.values)~="table" then
        runtime.saveStatus="Invalid file"
        WarnOnce("read","Invalid settings file. Kept unchanged until you change a setting.")
        return
    end
    if type(data.values.enabled)=="boolean" then runtime.values.enabled=data.values.enabled end
    runtime.values.maxItems=ClampItems(data.values.maxItems) or 9999
    runtime.saveStatus="Loaded"
end
local function SaveSettings()
    if not runtime.alive or runtime.initializing or not canPersist then return false end
    local ok,err=pcall(function()
        fileWrite(FILE,HttpService:JSONEncode({version=1,values={
            enabled=runtime.values.enabled,maxItems=runtime.values.maxItems,
        }}))
    end)
    if not ok then
        runtime.saveStatus="Write error"
        WarnOnce("write","Cannot save settings: " .. tostring(err))
        return false
    end
    warnings.write=nil
    runtime.saveStatus="Saved"
    return true
end
LoadSettings()

-- The original plugin's target heuristics are retained. No globals are patched.
local debugLibrary = type(debug)=="table" and debug or {}
local function Resolve(primary, fallback, external)
    if type(primary)=="function" then return primary end
    if type(fallback)=="function" then return fallback end
    if type(external)=="function" then return external end
end
local getGC = Resolve(getgc, environment.getgc)
local readUpvalues = Resolve(debugLibrary.getupvalues, getupvalues, environment.getupvalues)
local writeUpvalue = Resolve(debugLibrary.setupvalue, setupvalue, environment.setupvalue)
local readInfo = Resolve(debugLibrary.getinfo, getinfo, environment.getinfo)
local readConstants = Resolve(debugLibrary.getconstants, getconstants, environment.getconstants)
local readName = Resolve(debugLibrary.info)

local changed = {} -- [function][numeric upvalue index] = {original=..., last=...}
local connection
local statusLabel
local function Status(text)
    runtime.status=text
    if statusLabel then pcall(function() statusLabel:SetValue(text) end) end
end
local function IsTarget(fn)
    local name
    if readInfo then
        local ok,info=pcall(readInfo,fn)
        if ok and type(info)=="table" then name=info.name end
    elseif readName then
        local ok,value=pcall(readName,fn,"n")
        if ok then name=value end
    end
    if name=="updateItemFrame" or name=="onItemEquipped" then return true end
    if readConstants then
        local ok,constants=pcall(readConstants,fn)
        if ok and type(constants)=="table" then
            local touch,equip=false,false
            for _,value in pairs(constants) do
                if value=="TouchBinding" then touch=true end
                if value=="EquipButton" then equip=true end
            end
            return touch and equip
        end
    end
    return false
end
local function WriteAndVerify(fn,index,value)
    local ok,err=pcall(writeUpvalue,fn,index,value)
    if not ok then return false,tostring(err) end
    local readable,values=pcall(readUpvalues,fn)
    if not readable or type(values)~="table" or values[index]~=value then
        return false,"upvalue verification failed"
    end
    return true
end
local function RestoreOriginals()
    local allRestored=true
    for fn,slots in pairs(changed) do
        local readable,values=pcall(readUpvalues,fn)
        if not readable or type(values)~="table" then
            allRestored=false
            WarnOnce("restore-read","Could not inspect previously changed values; restoration is pending.")
        else
            for index,saved in pairs(slots) do
                local current=values[index]
                if current==saved.original then
                    slots[index]=nil
                elseif current~=saved.last then
                    -- Another script/game update owns the current value. Do not overwrite it.
                    WarnOnce("conflict","A value changed elsewhere; left it untouched.")
                    slots[index]=nil
                else
                    local ok,err=WriteAndVerify(fn,index,saved.original)
                    if ok then slots[index]=nil
                    else
                        allRestored=false
                        WarnOnce("restore-write","Cannot restore an original limit: " .. tostring(err))
                    end
                end
            end
        end
        if next(slots)==nil then changed[fn]=nil end
    end
    return allRestored
end
local function ApplyLimit()
    if not (getGC and readUpvalues and writeUpvalue and (readInfo or readName or readConstants)) then
        Status("UNSUPPORTED: required executor debug functions are missing")
        WarnOnce("debug","Required debug functions are unavailable (getgc/getupvalues/setupvalue and target identification).")
        return 0
    end
    local ok,objects=pcall(getGC)
    if not ok or type(objects)~="table" then
        Status("ERROR: getgc failed")
        WarnOnce("scan","getgc failed: " .. tostring(objects))
        return 0
    end
    local target=runtime.values.maxItems
    local count=0
    for _,fn in pairs(objects) do
        if type(fn)=="function" and (changed[fn] or IsTarget(fn)) then
            local readable,values=pcall(readUpvalues,fn)
            if readable and type(values)=="table" then
                for index,value in pairs(values) do
                    if type(index)=="number" and index>=1 and index%1==0 and type(value)=="number" then
                        local slots=changed[fn]
                        local saved=slots and slots[index]
                        -- Existing tracked values remain targets after any Max Items change.
                        if saved or value==10 or value==3 then
                            if not saved then
                                slots=slots or {};changed[fn]=slots
                                saved={original=value,last=value};slots[index]=saved
                            end
                            if value==target then
                                saved.last=target;count=count+1
                            elseif value==saved.last or value==saved.original then
                                -- Record intent before writing, so cleanup can recover even
                                -- if the executor writes but verification subsequently fails.
                                saved.last=target
                                local applied,err=WriteAndVerify(fn,index,target)
                                if applied then count=count+1
                                else WarnOnce("apply","Cannot write/verify a target limit: " .. tostring(err)) end
                            else
                                WarnOnce("conflict","A value changed elsewhere; left it untouched.")
                            end
                        end
                    end
                end
            end
        end
    end
    if count>0 then Status("ON | Max Items: " .. target .. " | verified values: " .. count)
    else Status("WAITING | Inventory functions not found or not writable") end
    return count
end
local function RequestApply()
    runtime.generation=runtime.generation+1
    local token=runtime.generation
    if not runtime.values.enabled then
        local restored=RestoreOriginals()
        Status(restored and "OFF | Original values restored" or "OFF | Restoration pending; press Reapply / Retry")
        return
    end
    Status("Applying saved/current limit...")
    -- Bounded retries, not a continuous getgc loop. Old requests are cancelled
    -- by any new setting change, disable, reload, or respawn.
    task.spawn(function()
        for _,delay in ipairs({0.2,0.8,2.0}) do
            task.wait(delay)
            if not runtime.alive or runtime.generation~=token or not runtime.values.enabled then return end
            ApplyLimit()
        end
    end)
end
runtime.Cleanup=function()
    runtime.alive=false
    runtime.generation=runtime.generation+1
    if connection then connection:Disconnect();connection=nil end
    return RestoreOriginals() -- do not persist OFF merely because the runtime is unloading
end
runtime.SaveSettings=SaveSettings

-- UI: CreateTab uses a GitHub path without domain and without .png.
local UI_VERSION=5
local ui
if type(previous)=="table" and type(previous.ui)=="table"
    and previous.ui.owner==shared and previous.ui.version==UI_VERSION and previous.ui.complete then
    ui=previous.ui
else
    local ok,result=pcall(function()
        local tab=shared.CreateTab("Inventory Unlimiter", "/mellnikovden968-web/CFG_PM2/refs/heads/main/icon")
        return {owner=shared,version=UI_VERSION,tab=tab,
            section=tab:AddSection("Inventory Unlimiter V5","Client-side limit • Saved preferences"),visual=false}
    end)
    if not ok then warn("[Inventory Unlimiter] UI failed: " .. tostring(result));return end
    ui=result
end
runtime.ui=ui
ui.runtime=runtime
_G[KEY]=runtime
runtime.SetEnabled=function(state)
    runtime.values.enabled=state==true
    SaveSettings()
    RequestApply()
end
runtime.SetMaxItems=function(value)
    local number=ClampItems(value)
    if not number then return end
    runtime.values.maxItems=number
    SaveSettings()
    if runtime.values.enabled then RequestApply() end
end
runtime.Reapply=RequestApply

if not ui.complete then
    local ok,err=pcall(function()
        ui.section:AddParagraph("Persistence", "Toggle and Max Items are saved on change. Load this plugin again after joining; saved preferences restore automatically.")
        ui.toggle=ui.section:AddToggle("Unlimit Inventory",function(value)
            ui.visual=value==true
            local active=ui.runtime
            if active and active.alive and not active.initializing then active.SetEnabled(value) end
        end)
        assert(type(ui.toggle)=="function","AddToggle must return a closure")
        ui.slider=ui.section:AddSlider("Max Items",2,9999,runtime.values.maxItems,function(value)
            local active=ui.runtime
            if active and active.alive and not active.initializing then active.SetMaxItems(value) end
        end)
        ui.status=ui.section:AddLabel("Initializing...",true)
        ui.section:AddButton("Reapply / Retry",function()
            local active=ui.runtime
            if active and active.alive and not active.initializing then active.Reapply() end
        end)
    end)
    if not ok then runtime.Cleanup();warn("[Inventory Unlimiter] UI controls failed: " .. tostring(err));return end
    ui.complete=true
end
statusLabel=ui.status
local synced,err=pcall(function()
    ui.slider:SetValue(runtime.values.maxItems)
    if ui.visual~=runtime.values.enabled then ui.toggle() end
    assert(ui.visual==runtime.values.enabled,"toggle state mismatch")
end)
if not synced then runtime.Cleanup();warn("[Inventory Unlimiter] UI sync failed: " .. tostring(err));return end
runtime.initializing=false

local LocalPlayer=game:GetService("Players").LocalPlayer
if LocalPlayer then
    connection=LocalPlayer.CharacterAdded:Connect(function()
        if runtime.alive and runtime.values.enabled then RequestApply() end
    end)
end
RequestApply()
print("[Inventory Unlimiter V5] Loaded | Settings: " .. FILE .. " | " .. runtime.saveStatus)
