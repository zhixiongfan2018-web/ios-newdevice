-- NewDevice / AMG-compatible script helpers (TouchSprite example)
-- Result files:
--   /var/jb/var/mobile/newdeviceResult.txt  (rootless)
--   /var/mobile/amgResult.txt              (AMG drop-in)
-- API: http://127.0.0.1:8080/cmd?fun=...

require "TSLib"

local sz = require("sz")
local http = require("szocket.http")

local function ResultPath()
    if isFileExist("/var/jb") then
        local p = "/var/jb/var/mobile/newdeviceResult.txt"
        if isFileExist(p) then return p end
    end
    if isFileExist("/var/mobile/amgResult.txt") then
        return "/var/mobile/amgResult.txt"
    end
    return "/var/mobile/newdeviceResult.txt"
end

function Check_NewDevice()
    -- API 由 NewDevice App 进程提供，必须先拉起 App（与 AMG 相同）
    if isFrontApp("com.local.newdevice") == 0 then
        runApp("com.local.newdevice")
        mSleep(3000)
    end
    local res, code = http.request("http://127.0.0.1:8080/")
    if code ~= 200 then
        toast("NewDevice API 未就绪，请打开 NewDevice App", 3)
        return false
    end
    return true
end

-- Alias for AMG scripts
Check_AMG = Check_NewDevice

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

Check_AMG_Result = Check_NewDevice_Result

local function ack(fun)
    if Check_NewDevice() == false then return false end
    local res, code = http.request("http://127.0.0.1:8080/cmd?fun=" .. fun)
    if code == 200 then return Check_NewDevice_Result() end
    return false
end

-- Keep AMG.* names for drop-in compatibility
local AMG = {
    Original = (function() return ack("originRecord") end),
    New = (function() return ack("newRecord") end),
    Next = (function() return ack("nextRecord") end),
    Prev = (function() return ack("prevRecord") end),
    First = (function() return ack("firstRecord") end),
    Delete_All = (function() return ack("deleteAllRecords") end),
    Disable_All = (function() return ack("disableAllRecord") end),
    Enable_All = (function() return ack("enableAllRecord") end),
    Clean = (function() return ack("clearAppData") end),
    Count = (function()
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=getRecordCount")
        if code == 200 and Check_NewDevice_Result() then return tonumber(res) end
    end),

    Get_Name = (function()
        Check_NewDevice()
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=getCurrentRecordName")
        if code == 200 and Check_NewDevice_Result() then return res end
    end),

    Recover = (function(record_name)
        return ack("setRecord&recordName=" .. record_name)
    end),
    Rename = (function(old_name, new_name)
        return ack("setRecordName&oldName=" .. old_name .. "&newName=" .. new_name)
    end),
    Delete = (function(record_name)
        return ack("deleteRecord&recordName=" .. record_name)
    end),
    Disable = (function(record_name)
        return ack("disableRecord&recordName=" .. record_name)
    end),
    Enable = (function(record_name)
        return ack("enableRecord&recordName=" .. record_name)
    end),

    Get_Param = (function()
        Check_NewDevice()
        local param_file = userPath() .. "/lua/AMG_Param.plist"
        if isFileExist(param_file) then delFile(param_file) end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=getCurrentRecordParam&saveFilePath=" .. param_file)
        if code == 200 and Check_NewDevice_Result() then return param_file end
    end),
    Set_Param = (function(param_file)
        return ack("setCurrentRecordParam&filePath=" .. param_file)
    end),
    Get_Spec_Param = (function(record_name)
        Check_NewDevice()
        local param_file = userPath() .. "/lua/AMG_Param.plist"
        if isFileExist(param_file) then delFile(param_file) end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=getRecordParam&recordName=" .. record_name .. "&saveFilePath=" .. param_file)
        if code == 200 and Check_NewDevice_Result() then return param_file end
    end),
    Set_Spec_Param = (function(record_name, param_file)
        return ack("setRecordParam&recordName=" .. record_name .. "&filePath=" .. param_file)
    end),
    Get_All_Record = (function()
        Check_NewDevice()
        local all_record_file = userPath() .. "/lua/AMG_All_Record.plist"
        if isFileExist(all_record_file) then delFile(all_record_file) end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=getAllRecordNames&saveFilePath=" .. all_record_file)
        if code == 200 and Check_NewDevice_Result() then return all_record_file end
    end),

    Import_AMG = (function(dir)
        Check_NewDevice()
        local q = "importAMGRecords"
        if dir and #dir > 0 then q = q .. "&dir=" .. dir end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=" .. q)
        if code == 200 and Check_NewDevice_Result() then return tonumber(res) or 0 end
        return 0
    end),

    -- Media/AMG/import · iGrimace · AWZ（与 App「工具」页一致）
    Import_AMG_Media = (function(dir)
        Check_NewDevice()
        local q = "importAMGMedia"
        if dir and #dir > 0 then q = q .. "&dir=" .. dir end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=" .. q)
        if code == 200 and Check_NewDevice_Result() then return tonumber(res) or 0 end
        return 0
    end),
    Import_IGrimace = (function(dir)
        Check_NewDevice()
        local q = "importIGrimace"
        if dir and #dir > 0 then q = q .. "&dir=" .. dir end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=" .. q)
        if code == 200 and Check_NewDevice_Result() then return tonumber(res) or 0 end
        return 0
    end),
    Import_AWZ = (function(dir)
        Check_NewDevice()
        local q = "importAWZ"
        if dir and #dir > 0 then q = q .. "&dir=" .. dir end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=" .. q)
        if code == 200 and Check_NewDevice_Result() then return tonumber(res) or 0 end
        return 0
    end),
    Export_AMG_Media = (function(dir, slim)
        Check_NewDevice()
        local q = "exportAMGMedia"
        if dir and #dir > 0 then q = q .. "&dir=" .. dir end
        if slim ~= nil then q = q .. "&slim=" .. (slim and "1" or "0") end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=" .. q)
        if code == 200 and Check_NewDevice_Result() then return res end
    end),
    Slim = (function(record_name)
        Check_NewDevice()
        local q = "slimRecord"
        if record_name and #record_name > 0 then q = q .. "&recordName=" .. record_name end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=" .. q)
        if code == 200 and Check_NewDevice_Result() then return tonumber(res) or 0 end
        return 0
    end),

    Export_Faker = (function(dir)
        Check_NewDevice()
        local out = dir
        if not out or #out == 0 then out = userPath() .. "/lua/AMG_Export" end
        local res, code = http.request("http://127.0.0.1:8080/cmd?fun=exportAMGFaker&dir=" .. out)
        if code == 200 and Check_NewDevice_Result() then return out end
    end),
}

-- example
-- if AMG.New() == true then toast("一键新机", 3) end
-- if AMG.Clean() == true then toast("强效清理", 3) end

return AMG
