--!native
--!optimize 2

local function SafeCall(func, ...)
    return xpcall(func, function(err) return tostring(err) end, ...)
end

local ScriptDumper = {}
ScriptDumper.__index = ScriptDumper

function ScriptDumper.new()
    local self = setmetatable({}, ScriptDumper)
    self.FunctionCache = {}
    return self
end

function ScriptDumper:AnalyzeProto(proto, index)
    local data = {
        Func = proto,
        Index = index,
        Name = "proto_" .. tostring(index),
        Line = 0,
        Constants = {},
        Upvalues = {},
    }
    SafeCall(function()
        local _, name, line = debug.info(proto, "sln")
        data.Line = tonumber(line) or 0
        data.Name = tostring(data.Line) .. ":" .. (name or "proto_" .. tostring(index))
    end)
    SafeCall(function() data.Constants = debug.getconstants(proto) end)
    SafeCall(function() data.Upvalues  = debug.getupvalues(proto)  end)
    return data
end

function ScriptDumper:AnalyzeFunction(func)
    local hash = ""
    SafeCall(function()
        local src, _, line = debug.info(func, "sln")
        hash = tostring(src) .. tostring(line)
    end)

    if self.FunctionCache[hash] then return nil end

    local data = {
        Func = func,
        Hash = hash,
        Name = "unknown",
        Source = "unknown",
        Line = 0,
        Constants = {},
        Upvalues = {},
        Protos = {},
    }

    SafeCall(function()
        local src, name, line = debug.info(func, "sln")
        data.Source = src or "unknown"
        data.Line   = tonumber(line) or 0
        data.Name   = tostring(data.Line) .. ":" .. (name or "anonymous")
    end)
    SafeCall(function() data.Constants = debug.getconstants(func) end)
    SafeCall(function() data.Upvalues  = debug.getupvalues(func)  end)
    SafeCall(function()
        local protos = debug.getprotos(func)
        for i, proto in ipairs(protos) do
            table.insert(data.Protos, self:AnalyzeProto(proto, i))
        end
    end)

    self.FunctionCache[hash] = data
    return data
end

function ScriptDumper:GetScriptFunctions(scriptName)
    local functions = {}
    SafeCall(function()
        local gcObjects = getgc(true)
        for _, obj in ipairs(gcObjects) do
            if typeof(obj) == "function" then
                local source = ""
                SafeCall(function() source = debug.info(obj, "s") or "" end)
                if source ~= "" and string.find(source, scriptName, 1, true) then
                    local fd = self:AnalyzeFunction(obj)
                    if fd then table.insert(functions, fd) end
                end
            end
        end
    end)
    table.sort(functions, function(a, b) return a.Line < b.Line end)
    return functions
end

local function SerializeValue(val)
    local t = typeof(val)
    if t == "string" then
        return '"' .. string.sub(val, 1, 60) .. (string.len(val) > 60 and '..."' or '"')
    elseif t == "function" then
        local info = ""
        SafeCall(function()
            local _, name, line = debug.info(val, "sln")
            info = (name or "anon") .. "@" .. tostring(line or "?")
        end)
        return "(function: " .. info .. ")"
    elseif t == "table" then
        local n = 0
        for _ in pairs(val) do n += 1 end
        return "(table[" .. n .. "])"
    else
        return tostring(val)
    end
end

function ScriptDumper:GenerateAnnotation(functions)
    if #functions == 0 then return "" end

    local lines = { "--[[ SCRIPT DUMPER — FUNCTION ANALYSIS", "" }

    for _, func in ipairs(functions) do
        local cCount, uCount = 0, 0
        for _ in pairs(func.Constants) do cCount += 1 end
        for _ in pairs(func.Upvalues)  do uCount += 1 end

        table.insert(lines, "     +-- FUNCTION: " .. func.Name)
        table.insert(lines, "     |   Source : " .. tostring(func.Source))
        table.insert(lines, "     |   Line   : " .. tostring(func.Line))
        table.insert(lines, "     |")
        table.insert(lines, "     |   @CONSTANTS (" .. cCount .. "):")
        for idx, val in pairs(func.Constants) do
            table.insert(lines, "     |     [" .. tostring(idx) .. "] = " .. SerializeValue(val) .. " (" .. typeof(val) .. ")")
        end
        table.insert(lines, "     |")
        table.insert(lines, "     |   @UPVALUES (" .. uCount .. "):")
        for idx, val in pairs(func.Upvalues) do
            table.insert(lines, "     |     [" .. tostring(idx) .. "] = " .. SerializeValue(val) .. " (" .. typeof(val) .. ")")
        end
        if #func.Protos > 0 then
            table.insert(lines, "     |")
            table.insert(lines, "     |   @PROTOS (" .. #func.Protos .. "):")
            for i, proto in ipairs(func.Protos) do
                local pc, pu = 0, 0
                for _ in pairs(proto.Constants) do pc += 1 end
                for _ in pairs(proto.Upvalues)  do pu += 1 end
                table.insert(lines, "     |     [" .. i .. "] " .. proto.Name .. " (C:" .. pc .. " U:" .. pu .. ")")
            end
        end
        table.insert(lines, "     +---------------------------------------------------------------")
        table.insert(lines, "")
    end

    table.insert(lines, "]]--")
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

local ussiSource = game:HttpGet("https://raw.githubusercontent.com/luau/UniversalSynSaveInstance/main/saveinstance.luau", true)

ussiSource = ussiSource:gsub("UniversalSynSaveInstance https://discord%.gg/%S+", "")
ussiSource = ussiSource:gsub("%-%- Decompiled with[^\n]*\n", "")

local synsaveinstance_original = loadstring(ussiSource, "saveinstance")()

local dumper = ScriptDumper.new()

local function synsaveinstance_modded(Options, ...)
    Options = Options or {}

    if Options.Decompile == nil then
        Options.Decompile = true
    end

    local userCallback = Options.Callback

    Options.Callback = function(scriptInstance, source)
        local annotated = (source or "")
            :gsub("%-%- Decompiled with[^\n]*\n", "")
            :gsub("UniversalSynSaveInstance https://discord%.gg/%S+[^\n]*\n?", "")

        if Options.Decompile and annotated ~= "" and not string.find(annotated, "-- Decompilation failed", 1, true) then
            local scriptName = ""
            SafeCall(function() scriptName = scriptInstance.Name end)

            if scriptName ~= "" then
                dumper.FunctionCache = {}
                local functions = dumper:GetScriptFunctions(scriptName)
                if #functions > 0 then
                    annotated = dumper:GenerateAnnotation(functions) .. annotated
                end
            end
        end

        if userCallback then
            return userCallback(scriptInstance, annotated)
        end

        return annotated
    end

    return synsaveinstance_original(Options, ...)
end

return synsaveinstance_modded
