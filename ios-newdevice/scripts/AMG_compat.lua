-- NewDevice / AMG-compatible script helpers (TouchSprite example)
-- Result file: /var/jb/var/mobile/newdeviceResult.txt or /var/mobile/newdeviceResult.txt
-- API: http://127.0.0.1:8080/cmd?fun=...

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
    -- 健康检查：打不开说明 App 未在前台/未安装/未编译安装最新版
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
        if code == 200 then return res end
        return nil
    end),
    Next = (function()
        return callAsync("nextRecord")
    end),
    First = (function()
        return callAsync("firstRecord")
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
}

-- example
-- if AMG.New() == true then toast("一键新机", 3) end

return AMG
