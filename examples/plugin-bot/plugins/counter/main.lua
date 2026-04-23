local current = tonumber(state_get("load_count"))
if current == nil then
    current = 0
end

function onLoad()
    log_info("onLoad")
    state_set("load_count", tostring(current + 1))
    state_set("status", "loaded")
end

function onEnable()
    log_info("onEnable")
    state_set("status", "enabled")
end

function onDisable()
    log_warn("onDisable")
    state_set("status", "disabled")
end
