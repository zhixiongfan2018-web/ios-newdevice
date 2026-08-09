-- NewDevice / AMG-compatible script helpers (TouchSprite example)
-- Result file: /var/jb/var/mobile/newdeviceResult.txt or /var/mobile/newdeviceResult.txt
-- API: http://127.0.0.1:8080/cmd?fun=...

require "TSLib"

local sz = require("sz")
local http = require("szocket.http")

local function ResultPath()
    if isFileExist("/var/jb/var/mobile/newdeviceResult.txt") or true then
        if isFileExist("/var/jb") then
            return "/var/jb/var/mobile/newdeviceResult.txt"
        end
    end
    return "/var/mobile/newdeviceResult.txt"
end

function Check_NewDevice()
    -- API 由 NewDevice App 进程提供，必须先拉起 App（与 AMG 相同）
    if isFrontApp("com.local.newdevice") == 0 then
        runApp("com.local.newdevice")
        mSleep(3000)
    end
    -- 健康检查：打不开说明 App 未在前台/未安装/未编译安装最新版
    local res, code = http.request("http://127.0.0.1:8080/")
    if code ~= 200 then
        toast("NewDevice API 未就绪，请打开 NewDevice App", 3)
        return false
    end
    return true
end

function Check_NewDevice_Result()
    ::get_result::
    mSleep(2000)
    local result_file = ResultPath()
    if isFileExist(result_file) then
        local r = readFileString(result_file)
        if r == "0" then
            return false
        elseif r == "1" then
            return true
        elseif r == "2" then
            toast("执行中", 1)
            goto get_result
        end
    end
    return false
end

-- Keep AMG.* names for drop-in compatibility
local AMG = {
    Original = (function()
        if Check_NewDevice() == false then return false end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=originRecord")
        if code == 200 then return Check_NewDevice_Result() end
    end),
    New = (function()
        if Check_NewDevice() == false then return false end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=newRecord")
        if code == 200 then return Check_NewDevice_Result() end
    end),
    Get_Name = (function()
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=getCurrentRecordName")
        if code == 200 and Check_NewDevice_Result() then return res end
    end),
    Next = (function()
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=nextRecord")
        if code == 200 then return Check_NewDevice_Result() end
    end),
    First = (function()
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=firstRecord")
        if code == 200 then return Check_NewDevice_Result() end
    end),
    Recover = (function(record_name)
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=setRecord&recordName=" .. record_name)
        if code == 200 then return Check_NewDevice_Result() end
    end),
    Rename = (function(old_name, new_name)
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=setRecordName&oldName=" .. old_name .. "&newName=" .. new_name)
        if code == 200 then return Check_NewDevice_Result() end
    end),
    Delete = (function(record_name)
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=deleteRecord&recordName=" .. record_name)
        if code == 200 then return Check_NewDevice_Result() end
    end),
    Delete_All = (function()
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=deleteAllRecords")
        if code == 200 then return Check_NewDevice_Result() end
    end),
}

-- example
-- if AMG.New() == true then toast("一键新机", 3) end

return AMG
