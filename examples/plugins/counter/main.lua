local current = tonumber(state_get("load_count"))
if current == nil then
    current = 0
end

function onLoad()
    state_set("load_count", tostring(current + 1))
    state_set("status", "loaded")
end

function onEnable()
    state_set("status", "enabled")
end

function onDisable()
    state_set("status", "disabled")
end
