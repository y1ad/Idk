--!native
--!optimize 2

local ussiSource = game:HttpGet("https://raw.githubusercontent.com/luau/UniversalSynSaveInstance/main/saveinstance.luau", true)

ussiSource = ussiSource:gsub("UniversalSynSaveInstance https://discord%.gg/%S+", "")
ussiSource = ussiSource:gsub("%-%- Decompiled with[^\n]*\n", "")

return loadstring(ussiSource, "saveinstance")()
