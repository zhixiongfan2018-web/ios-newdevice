-- NewDevice / AMG-compatible script helpers (TouchSprite example)
-- Result file: /var/jb/var/mobile/newdeviceResult.txt or /var/mobile/newdeviceResult.txt
-- API: http://127.0.0.1:8080/cmd?fun=...
-- Param keys (align with AMG): IDFA, IDFV, UUID, Serial, UDID, WiFiMAC, BTMAC,
--   DeviceToken, Model, ProductType, HardwareMachine, HardwareModel, SystemVer,
--   Build, Carrier, MCC, MNC, RadioAccess, Latitude, Longitude, Altitude

require "TSLib"

local sz = require("sz")
local http = require("szocket.http")

local RESULT_POLL_INTERVAL_MS = 2000
local RESULT_POLL_MAX_TRIES = 90 -- ~3 minutes

local function ResultPath()
    if isFileExist("/var/jb") then
        return "/var/jb/var/mobile/newdeviceResult.txt"
    end
    return "/var/mobile/newdeviceResult.txt"
end

local function urlencode(s)
    if s == nil then return "" end
    s = tostring(s)
    s = string.gsub(s, "\n", "\r\n")
    s = string.gsub(s, "([^%w%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return s
end

local function apiGet(path)
    local res, code = http.request("http://127.0.0.1:8080" .. path)
    return res, code
end

function Check_NewDevice()
    -- API 由 NewDevice App 进程提供，必须先拉起 App（与 AMG 相同）
    if isFrontApp("com.local.newdevice") == 0 then
        runApp("com.local.newdevice")
        mSleep(3000)
    end
    local res, code = apiGet("/")
    if code ~= 200 then
        toast("NewDevice API 未就绪，请打开 NewDevice App", 3)
        return false
    end
    return true
end

function Check_NewDevice_Result()
    local tries = 0
    while tries < RESULT_POLL_MAX_TRIES do
        tries = tries + 1
        mSleep(RESULT_POLL_INTERVAL_MS)
        local result_file = ResultPath()
        if isFileExist(result_file) then
            local r = readFileString(result_file)
            r = (r or ""):gsub("%s+", "")
            if r == "0" then
                return false
            elseif r == "1" then
                return true
            elseif r == "2" then
                toast("执行中", 1)
            end
        end
    end
    toast("等待结果超时", 2)
    return false
end

local function callAsync(fun, query)
    if Check_NewDevice() == false then return false end
    local path = "/cmd?fun=" .. urlencode(fun)
    if query then
        for k, v in pairs(query) do
            path = path .. "&" .. urlencode(k) .. "=" .. urlencode(v)
        end
    end
    local res, code = apiGet(path)
    if code == 200 then
        return Check_NewDevice_Result()
    end
    return false
end

local function callParamGet(fun, query)
    if Check_NewDevice() == false then return nil end
    local path = "/cmd?fun=" .. urlencode(fun)
    if query then
        for k, v in pairs(query) do
            path = path .. "&" .. urlencode(k) .. "=" .. urlencode(v)
        end
    end
    local res, code = apiGet(path)
    if code == 200 and Check_NewDevice_Result() then
        return query and query.saveFilePath or res
    end
    return nil
end

-- Keep AMG.* names for drop-in compatibility
local AMG = {
    Original = (function()
        return callAsync("originRecord")
    end),
    New = (function()
        return callAsync("newRecord")
    end),
    Get_Name = (function()
        if Check_NewDevice() == false then return nil end
        local res, code = apiGet("/cmd?fun=getCurrentRecordName")
        if code == 200 and Check_NewDevice_Result() then return res end
        return nil
    end),
    Next = (function()
        return callAsync("nextRecord")
    end),
    First = (function()
        return callAsync("firstRecord")
    end),
    Get_Param = (function()
        -- Same default path style as AMG docs; caller may move file afterward.
        local param_file = userPath() .. "/lua/AMG_Param.plist"
        if isFileExist(param_file) then delFile(param_file) end
        return callParamGet("getCurrentRecordParam", { saveFilePath = param_file })
    end),
    Set_Param = (function(param_file)
        return callAsync("setCurrentRecordParam", { filePath = param_file })
    end),
    Get_Spec_Param = (function(record_name)
        local param_file = userPath() .. "/lua/AMG_Param.plist"
        if isFileExist(param_file) then delFile(param_file) end
        return callParamGet("getRecordParam", { recordName = record_name, saveFilePath = param_file })
    end),
    Set_Spec_Param = (function(record_name, param_file)
        return callAsync("setRecordParam", { recordName = record_name, filePath = param_file })
    end),
    Get_All_Record = (function()
        local all_record_file = userPath() .. "/lua/AMG_All_Record.plist"
        if isFileExist(all_record_file) then delFile(all_record_file) end
        return callParamGet("getAllRecordNames", { saveFilePath = all_record_file })
    end),
    Recover = (function(record_name)
        return callAsync("setRecord", { recordName = record_name })
    end),
    Rename = (function(old_name, new_name)
        return callAsync("setRecordName", { oldName = old_name, newName = new_name })
    end),
    Delete = (function(record_name)
        return callAsync("deleteRecord", { recordName = record_name })
    end),
    Delete_All = (function()
        return callAsync("deleteAllRecords")
    end),
    Disable = (function(record_name)
        return callAsync("disableRecord", { recordName = record_name })
    end),
    Enable = (function(record_name)
        return callAsync("enableRecord", { recordName = record_name })
    end),
    Disable_All = (function()
        return callAsync("disableAllRecord")
    end),
    Enable_All = (function()
        return callAsync("enableAllRecord")
    end),
}

-- example
-- if AMG.New() == true then toast("一键新机", 3) end
-- local f = AMG.Get_Param(); if f then toast(f, 3) end

return AMG
