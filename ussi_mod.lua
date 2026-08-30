--!native
--!optimize 2

local function SafeCall(func, ...)
    return xpcall(func, function(err) return tostring(err) end, ...)
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

local FunctionCache = {}

local function AnalyzeProto(proto, index)
    local data = { Func = proto, Index = index, Name = "proto_" .. index, Line = 0, Constants = {}, Upvalues = {} }
    SafeCall(function()
        local _, name, line = debug.info(proto, "sln")
        data.Line = tonumber(line) or 0
        data.Name = tostring(data.Line) .. ":" .. (name or "proto_" .. index)
    end)
    SafeCall(function() data.Constants = debug.getconstants(proto) end)
    SafeCall(function() data.Upvalues  = debug.getupvalues(proto)  end)
    return data
end

local function AnalyzeFunction(func)
    local hash = ""
    SafeCall(function()
        local src, _, line = debug.info(func, "sln")
        hash = tostring(src) .. tostring(line)
    end)
    if FunctionCache[hash] then return nil end
    local data = { Func = func, Hash = hash, Name = "unknown", Source = "unknown", Line = 0, Constants = {}, Upvalues = {}, Protos = {} }
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
            table.insert(data.Protos, AnalyzeProto(proto, i))
        end
    end)
    FunctionCache[hash] = data
    return data
end

local function GetScriptFunctions(scriptName)
    local functions = {}
    SafeCall(function()
        for _, obj in ipairs(getgc(true)) do
            if typeof(obj) == "function" then
                local source = ""
                SafeCall(function() source = debug.info(obj, "s") or "" end)
                if source ~= "" and string.find(source, scriptName, 1, true) then
                    local fd = AnalyzeFunction(obj)
                    if fd then table.insert(functions, fd) end
                end
            end
        end
    end)
    table.sort(functions, function(a, b) return a.Line < b.Line end)
    return functions
end

local function GenerateAnnotation(functions)
    if #functions == 0 then return "" end
    local lines = { "--[[ SCRIPT DUMPER — FUNCTION ANALYSIS", "" }
    for _, func in ipairs(functions) do
        local cCount, uCount = 0, 0
        for _ in pairs(func.Constants) do cCount += 1 end
        for _ in pairs(func.Upvalues)  do uCount += 1 end
        table.insert(lines, "     +-- FUNCTION: " .. func.Name)
        table.insert(lines, "     |   Line   : " .. tostring(func.Line))
        table.insert(lines, "     |   @CONSTANTS (" .. cCount .. "):")
        for idx, val in pairs(func.Constants) do
            table.insert(lines, "     |     [" .. tostring(idx) .. "] = " .. SerializeValue(val) .. " (" .. typeof(val) .. ")")
        end
        table.insert(lines, "     |   @UPVALUES (" .. uCount .. "):")
        for idx, val in pairs(func.Upvalues) do
            table.insert(lines, "     |     [" .. tostring(idx) .. "] = " .. SerializeValue(val) .. " (" .. typeof(val) .. ")")
        end
        if #func.Protos > 0 then
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

local function FindLatestRbxlx()
    local files = listfiles("")
    local latest = nil
    for _, f in ipairs(files) do
        local ext = string.sub(f, -6)
        if ext == ".rbxlx" or ext == ".rbxmx" or string.sub(f, -5) == ".rbxl" then
            latest = f
        end
    end
    return latest
end

local ussiSource = game:HttpGet("https://raw.githubusercontent.com/luau/UniversalSynSaveInstance/main/saveinstance.luau", true)
ussiSource = ussiSource:gsub("UniversalSynSaveInstance https://discord%.gg/%S+", "")
ussiSource = ussiSource:gsub("%-%- Decompiled with[^\n]*\n", "")
local synsaveinstance_original = loadstring(ussiSource, "saveinstance")()

return function(Options, ...)
    Options = Options or {}
    if Options.Decompile == nil then Options.Decompile = true end

    synsaveinstance_original(Options, ...)

    task.wait(1)

    local filePath = FindLatestRbxlx()
    if not filePath then
        print("[MOD] No se encontró ningún .rbxlx")
        return
    end

    print("[MOD] Parcheando: " .. filePath)
    local content = readfile(filePath)

    content = content:gsub(
        '(<string name="Name">)(.-)(</string>)(.-<ProtectedString name="Source"><!\[CDATA\[)(.-)(]\]></ProtectedString>)',
        function(nameOpen, scriptName, nameClose, middle, src)
            FunctionCache = {}
            local funcs = GetScriptFunctions(scriptName)
            local annotation = GenerateAnnotation(funcs)
            src = src:gsub("%-%- Decompiled with[^\n]*\n", "")
            src = src:gsub("UniversalSynSaveInstance https://discord%.gg/%S+[^\n]*\n?", "")
            return nameOpen .. scriptName .. nameClose .. middle .. "<![CDATA[" .. annotation .. src .. "]]></ProtectedString>"
        end
    )

    writefile(filePath, content)
    print("[MOD] Listo — " .. filePath)
end
