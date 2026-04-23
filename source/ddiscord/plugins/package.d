/**
 * ddiscord — plugin registry and runtime.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.plugins;

import ddiscord.logging : Logger;
import ddiscord.scripting : LuaCapability, LuaExpose, LuaRuntime, LuaSandboxProfile, ScriptingEngine,
    allLuaCapabilities;
import ddiscord.state : StateStore;
import ddiscord.util.errors : formatError;
import ddiscord.util.optional : Nullable;
import std.algorithm : canFind;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, getSize, isDir, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath, dirName, extension, relativePath;
import std.string : startsWith;

/// The plugin manifest API generation supported by this build.
enum CurrentPluginApiVersion = "2";

/// UDA that marks a Lua-backed plugin descriptor.
struct LuaPlugin
{
    string name;
    string entrypoint;
    LuaSandboxProfile sandbox;

    this(string name, string entrypoint = "", LuaSandboxProfile sandbox = LuaSandboxProfile.Untrusted)
    {
        this.name = name;
        this.entrypoint = entrypoint;
        this.sandbox = sandbox;
    }
}

/// Metadata extracted from a registered plugin descriptor.
struct PluginDescriptor
{
    string typeName;
    string pluginName;
    string entrypoint;
    string resolvedEntrypoint;
    string pluginVersion = "0.0.0";
    string apiVersion = CurrentPluginApiVersion;
    LuaSandboxProfile sandbox = LuaSandboxProfile.Untrusted;
    LuaCapability[] permissions;
}

/// Observable state for a loaded plugin runtime.
struct PluginRuntimeState
{
    PluginDescriptor descriptor;
    bool enabled;
    string[] lifecycleHooks;
    Nullable!string lastError;
}

/// Hardening options for file-based plugin discovery and activation.
struct PluginSecurityPolicy
{
    /// When false, only manifest-driven plugins are loaded.
    bool allowLooseScripts = true;

    /// When false, manifest entrypoints must stay under the plugin directory.
    bool allowEntrypointOutsidePluginDirectory = false;

    /// When true, untrusted file plugins without declared permissions receive zero host capabilities.
    bool requireDeclaredPermissionsForUntrusted = false;

    /// Maximum accepted plugin manifest size in bytes.
    size_t maxManifestBytes = 256 * 1024;
}

private struct PluginHostApi
{
    string pluginName;
    string pluginVersion;
    string pluginApiVersion;
    string pluginEntrypoint;
    string pluginSandbox;
    StateStore state;
    Logger logger;

    @LuaExpose("plugin_name", LuaCapability.ContextRead)
    string pluginNameValue()
    {
        return pluginName;
    }

    @LuaExpose("plugin_version", LuaCapability.ContextRead)
    string pluginVersionValue()
    {
        return pluginVersion;
    }

    @LuaExpose("plugin_api_version", LuaCapability.ContextRead)
    string pluginApiVersionValue()
    {
        return pluginApiVersion;
    }

    @LuaExpose("plugin_entrypoint", LuaCapability.ContextRead)
    string pluginEntrypointValue()
    {
        return pluginEntrypoint;
    }

    @LuaExpose("plugin_sandbox", LuaCapability.ContextRead)
    string pluginSandboxValue()
    {
        return pluginSandbox;
    }

    @LuaExpose("state_prefix", LuaCapability.ContextRead)
    string statePrefix()
    {
        return "plugin:" ~ pluginName ~ ":";
    }

    @LuaExpose("state_get", LuaCapability.StateRead)
    string stateGet(string key)
    {
        return state.global.getOr!string("plugin:" ~ pluginName ~ ":" ~ key, "");
    }

    @LuaExpose("state_set", LuaCapability.StateWrite)
    void stateSet(string key, string value)
    {
        state.global.set("plugin:" ~ pluginName ~ ":" ~ key, value);
    }

    @LuaExpose("state_has", LuaCapability.StateRead)
    bool stateHas(string key)
    {
        return state.global.has("plugin:" ~ pluginName ~ ":" ~ key);
    }

    @LuaExpose("state_del", LuaCapability.StateWrite)
    void stateDelete(string key)
    {
        state.global.remove("plugin:" ~ pluginName ~ ":" ~ key);
    }

    @LuaExpose("log_info", LuaCapability.LogWrite)
    void logInfo(string message)
    {
        if (logger is null)
            return;
        logger.information("plugins", "[" ~ pluginName ~ "] " ~ message);
    }

    @LuaExpose("log_warn", LuaCapability.LogWrite)
    void logWarn(string message)
    {
        if (logger is null)
            return;
        logger.warning("plugins", "[" ~ pluginName ~ "] " ~ message);
    }

    @LuaExpose("log_error", LuaCapability.LogWrite)
    void logError(string message)
    {
        if (logger is null)
            return;
        logger.error("plugins", "[" ~ pluginName ~ "] " ~ message);
    }
}

private final class LoadedPlugin
{
    PluginDescriptor descriptor;
    LuaRuntime runtime;
    bool enabled;
    string[] lifecycleHooks;
    Nullable!string lastError;
}

/// Minimal plugin registry with real Lua activation.
final class PluginRegistry
{
    Logger logger;
    PluginSecurityPolicy security;

    private PluginDescriptor[] _descriptors;
    private LoadedPlugin[] _loaded;
    private string[] _loadErrors;

    /// Registers a plugin descriptor type.
    void register(T)()
    {
        PluginDescriptor descriptor;
        descriptor.typeName = T.stringof;

        static foreach (attr; __traits(getAttributes, T))
        {
            static if (is(typeof(attr) == LuaPlugin))
            {
                descriptor.pluginName = attr.name;
                descriptor.entrypoint = attr.entrypoint;
                descriptor.resolvedEntrypoint = attr.entrypoint;
                descriptor.sandbox = attr.sandbox;
            }
        }

        if (descriptor.pluginName.length == 0)
            descriptor.pluginName = T.stringof;

        appendIfMissing(descriptor);
    }

    /// Loads file-based plugin descriptors from a directory.
    void loadAll(string directory = "plugins")
    {
        if (!exists(directory) || !isDir(directory))
            return;

        foreach (entry; dirEntries(directory, SpanMode.depth))
        {
            if (entry.isDir)
                continue;

            if (baseName(entry.name) == "plugin.json")
            {
                loadManifest(entry.name, directory);
                continue;
            }

            if (extension(entry.name) == ".lua")
            {
                if (!security.allowLooseScripts)
                    continue;
                loadLooseScript(entry.name, directory);
            }
        }
    }

    /// Activates every discovered file-based Lua plugin.
    void activateAll(ScriptingEngine scripting, StateStore state)
    {
        _loaded.length = 0;
        _loadErrors.length = 0;

        foreach (descriptor; _descriptors)
        {
            LoadedPlugin loaded = new LoadedPlugin;
            loaded.descriptor = descriptor;

            if (descriptor.resolvedEntrypoint.length == 0)
            {
                _loaded ~= loaded;
                continue;
            }

            if (descriptor.apiVersion != CurrentPluginApiVersion)
            {
                auto message = formatError(
                    "plugins",
                    "A plugin declared an incompatible ddiscord API version.",
                    "Plugin `" ~ descriptor.pluginName ~ "` requested API `" ~ descriptor.apiVersion ~ "` but this build supports `" ~ CurrentPluginApiVersion ~ "`.",
                    "Update the plugin manifest or upgrade the library so both sides agree on `ddiscordApiVersion`."
                );
                loaded.lastError = Nullable!string.of(message);
                _loadErrors ~= message;
                if (logger !is null)
                    logger.error("plugins", message);
                _loaded ~= loaded;
                continue;
            }

            if (!exists(descriptor.resolvedEntrypoint))
            {
                auto message = formatError(
                    "plugins",
                    "A plugin entrypoint could not be found on disk.",
                    "Plugin `" ~ descriptor.pluginName ~ "` expected `" ~ descriptor.resolvedEntrypoint ~ "`.",
                    "Check `plugin.json`, the configured plugins directory, or the current working directory."
                );
                loaded.lastError = Nullable!string.of(message);
                _loadErrors ~= message;
                if (logger !is null)
                    logger.error("plugins", message);
                _loaded ~= loaded;
                continue;
            }

            auto permissions = effectivePermissions(descriptor, security);
            if (permissions.length == 0 && logger !is null)
            {
                logger.warning(
                    "plugins",
                    "Plugin `" ~ descriptor.pluginName ~ "` is untrusted and did not declare permissions; host API exports were disabled by policy."
                );
            }

            auto runtime = scripting.open!PluginHostApi(
                PluginHostApi(
                    descriptor.pluginName,
                    descriptor.pluginVersion,
                    descriptor.apiVersion,
                    descriptor.resolvedEntrypoint,
                    sandboxLabel(descriptor.sandbox),
                    state,
                    logger
                ),
                descriptor.sandbox,
                permissions
            );

            auto evalResult = runtime.evalFile(descriptor.resolvedEntrypoint);
            if (evalResult.isErr)
            {
                auto location = scriptLocationLabel(descriptor, evalResult.error.line);
                auto message = formatError(
                    "plugins",
                    "A Lua plugin failed during file evaluation.",
                    "Plugin `" ~ descriptor.pluginName ~ "` raised at `" ~ location ~ "`: " ~ evalResult.error.message,
                    "Fix the script syntax/runtime error; the plugin stayed disabled and the bot kept running."
                );
                loaded.lastError = Nullable!string.of(message);
                _loadErrors ~= message;
                if (logger !is null)
                    logger.error("plugins", message);
                _loaded ~= loaded;
                continue;
            }

            loaded.runtime = runtime;

            if (!callLifecycleHook(loaded, "onLoad"))
            {
                _loaded ~= loaded;
                continue;
            }

            if (!callLifecycleHook(loaded, "onEnable"))
            {
                _loaded ~= loaded;
                continue;
            }

            loaded.enabled = true;
            if (logger !is null)
            {
                logger.information(
                    "plugins",
                    "Activated plugin `" ~ descriptor.pluginName ~ "` from `" ~ descriptor.resolvedEntrypoint ~ "`."
                );
            }
            _loaded ~= loaded;
        }
    }

    /// Deactivates every active plugin runtime.
    void deactivateAll()
    {
        foreach_reverse (loaded; _loaded)
        {
            if (!loaded.enabled)
                continue;

            if (!loaded.runtime.hasCallable("onDisable"))
            {
                if (loaded.runtime.hasCallable("onUnload"))
                    callLifecycleHook(loaded, "onUnload");
                loaded.enabled = false;
                if (logger !is null)
                    logger.information("plugins", "Deactivated plugin `" ~ loaded.descriptor.pluginName ~ "`.");
                continue;
            }

            if (callLifecycleHook(loaded, "onDisable") && loaded.runtime.hasCallable("onUnload"))
                callLifecycleHook(loaded, "onUnload");

            loaded.enabled = false;
            if (logger !is null)
                logger.information("plugins", "Deactivated plugin `" ~ loaded.descriptor.pluginName ~ "`.");
        }
    }

    /// Returns registered plugin descriptor names.
    string[] registeredNames() const @property
    {
        string[] names;
        foreach (descriptor; _descriptors)
            names ~= descriptor.pluginName;
        return names;
    }

    /// Returns full descriptors.
    PluginDescriptor[] descriptors() @property
    {
        return _descriptors.dup;
    }

    /// Returns the current runtime states for loaded plugins.
    PluginRuntimeState[] runtimeStates() @property
    {
        PluginRuntimeState[] states;

        foreach (loaded; _loaded)
        {
            PluginRuntimeState state;
            state.descriptor = loaded.descriptor;
            state.enabled = loaded.enabled;
            state.lifecycleHooks = loaded.lifecycleHooks.dup;
            state.lastError = loaded.lastError;
            states ~= state;
        }

        return states;
    }

    /// Returns plugin load/activation errors captured so far.
    string[] loadErrors() const @property
    {
        return _loadErrors.dup;
    }

    /// Finds a plugin by public name.
    Nullable!PluginDescriptor find(string name)
    {
        foreach (descriptor; _descriptors)
        {
            if (descriptor.pluginName == name)
                return Nullable!PluginDescriptor.of(descriptor);
        }

        return Nullable!PluginDescriptor.init;
    }

    private bool callLifecycleHook(LoadedPlugin loaded, string hookName)
    {
        if (!loaded.runtime.hasCallable(hookName))
            return true;

        auto result = loaded.runtime.call(hookName);
        if (result.isErr)
        {
            auto location = scriptLocationLabel(loaded.descriptor, result.error.line);
            auto message = formatError(
                "plugins",
                "A Lua plugin failed during lifecycle execution.",
                "Plugin `" ~ loaded.descriptor.pluginName ~ "` hook `" ~ hookName ~ "` failed at `" ~
                    location ~ "`: " ~ result.error.message,
                "Fix the script hook or remove it; the failing plugin was isolated."
            );
            loaded.lastError = Nullable!string.of(message);
            _loadErrors ~= message;
            if (logger !is null)
                logger.error("plugins", message);
            return false;
        }

        loaded.lifecycleHooks ~= hookName;
        return true;
    }

    private string scriptLocationLabel(PluginDescriptor descriptor, size_t line)
    {
        auto path = descriptor.entrypoint.length != 0 ? descriptor.entrypoint : descriptor.resolvedEntrypoint;
        if (path.length == 0)
            path = "<unknown>";

        if (line == 0)
            return path;
        return path ~ ":" ~ line.to!string;
    }

    private void loadManifest(string manifestPath, string rootDirectory)
    {
        if (security.maxManifestBytes > 0)
        {
            try
            {
                auto bytes = getSize(manifestPath);
                if (bytes > security.maxManifestBytes)
                {
                    auto message = formatError(
                        "plugins",
                        "A plugin manifest exceeded the configured size limit.",
                        "Manifest `" ~ manifestPath ~ "` has `" ~ bytes.to!string ~ "` bytes.",
                        "Reduce the manifest size or increase `PluginRegistry.security.maxManifestBytes`."
                    );
                    _loadErrors ~= message;
                    if (logger !is null)
                        logger.error("plugins", message);
                    return;
                }
            }
            catch (Exception error)
            {
                if (logger !is null)
                {
                    logger.warning(
                        "plugins",
                        "Could not determine manifest size for `" ~ manifestPath ~ "`; continuing without size guard. detail=" ~ error.msg
                    );
                }
            }
        }

        JSONValue json;
        try
            json = parseJSON(readText(manifestPath));
        catch (Exception error)
        {
            auto message = formatError(
                "plugins",
                "A plugin manifest could not be parsed as JSON.",
                "Manifest `" ~ manifestPath ~ "` failed with: " ~ error.msg,
                "Fix the JSON syntax before starting the bot again."
            );
            _loadErrors ~= message;
            if (logger !is null)
                logger.error("plugins", message);
            return;
        }

        PluginDescriptor descriptor;
        descriptor.typeName = "lua:" ~ manifestPath;

        descriptor.pluginName = jsonStringValue(json, "name");
        auto versionText = jsonStringValue(json, "version");
        if (versionText.length != 0)
            descriptor.pluginVersion = versionText;
        auto apiVersion = jsonStringValue(json, "ddiscordApiVersion");
        if (apiVersion.length != 0)
            descriptor.apiVersion = apiVersion;

        auto sandboxValue = jsonStringValue(json, "sandbox");
        if (sandboxValue == "trusted")
            descriptor.sandbox = LuaSandboxProfile.Trusted;

        auto permissionsValue = json.object.get("permissions", JSONValue.init);
        if (permissionsValue.type == JSONType.array)
        {
            foreach (item; permissionsValue.array)
            {
                if (item.type != JSONType.string)
                    continue;
                auto permission = parseCapability(item.str);
                if (!permission.isNull)
                    descriptor.permissions ~= permission.get;
            }
        }

        bool explicitEntrypointRequested;

        auto scriptsValue = json.object.get("scripts", JSONValue.init);
        if (scriptsValue.type == JSONType.array)
        {
            explicitEntrypointRequested = true;
            foreach (item; scriptsValue.array)
            {
                if (item.type != JSONType.string)
                    continue;

                auto resolved = resolveManifestScriptPath(
                    item.str,
                    manifestPath,
                    security.allowEntrypointOutsidePluginDirectory
                );
                if (resolved.isNull)
                    continue;
                descriptor.entrypoint = relativeOrOriginal(resolved.get, rootDirectory);
                descriptor.resolvedEntrypoint = resolved.get;
                break;
            }
        }

        auto entrypoint = jsonStringValue(json, "entrypoint");
        if (descriptor.entrypoint.length == 0 && entrypoint.length != 0)
        {
            explicitEntrypointRequested = true;
            auto resolved = resolveManifestScriptPath(
                entrypoint,
                manifestPath,
                security.allowEntrypointOutsidePluginDirectory
            );
            if (!resolved.isNull)
            {
                descriptor.entrypoint = relativeOrOriginal(resolved.get, rootDirectory);
                descriptor.resolvedEntrypoint = resolved.get;
            }
        }

        if (descriptor.pluginName.length == 0)
            descriptor.pluginName = baseName(dirName(manifestPath));

        if (descriptor.entrypoint.length == 0 && !explicitEntrypointRequested)
        {
            auto fallback = resolveManifestScriptPath(
                "main.lua",
                manifestPath,
                security.allowEntrypointOutsidePluginDirectory
            );
            if (!fallback.isNull)
            {
                descriptor.entrypoint = relativeOrOriginal(fallback.get, rootDirectory);
                descriptor.resolvedEntrypoint = fallback.get;
            }
        }

        if (descriptor.resolvedEntrypoint.length == 0)
        {
            auto message = formatError(
                "plugins",
                "A plugin manifest points to an invalid entrypoint path.",
                "Manifest `" ~ manifestPath ~ "` does not resolve to a safe Lua file path.",
                "Set `entrypoint`/`scripts` to a file inside the plugin directory or enable `allowEntrypointOutsidePluginDirectory`."
            );
            _loadErrors ~= message;
            if (logger !is null)
                logger.error("plugins", message);
            return;
        }

        appendIfMissing(descriptor);
    }

    private void loadLooseScript(string scriptPath, string rootDirectory)
    {
        if (exists(buildPath(dirName(scriptPath), "plugin.json")))
            return;

        PluginDescriptor descriptor;
        descriptor.typeName = "lua:" ~ scriptPath;
        descriptor.pluginName = baseName(scriptPath);
        auto resolved = absolutePath(scriptPath);
        descriptor.entrypoint = relativeOrOriginal(resolved, rootDirectory);
        descriptor.resolvedEntrypoint = resolved;
        descriptor.sandbox = LuaSandboxProfile.Untrusted;
        appendIfMissing(descriptor);
    }

    private void appendIfMissing(PluginDescriptor descriptor)
    {
        foreach (index, existing; _descriptors)
        {
            if (existing.pluginName == descriptor.pluginName)
            {
                auto existingHasRealEntrypoint =
                    existing.resolvedEntrypoint.length != 0 &&
                    exists(existing.resolvedEntrypoint);
                auto incomingHasRealEntrypoint =
                    descriptor.resolvedEntrypoint.length != 0 &&
                    exists(descriptor.resolvedEntrypoint);

                if (!existingHasRealEntrypoint && incomingHasRealEntrypoint)
                    _descriptors[index] = descriptor;
                return;
            }

            if (descriptor.resolvedEntrypoint.length != 0 && existing.resolvedEntrypoint == descriptor.resolvedEntrypoint)
                return;
        }

        _descriptors ~= descriptor;
    }
}

private Nullable!string resolveManifestScriptPath(
    string entry,
    string manifestPath,
    bool allowOutsidePluginDirectory
)
{
    if (entry.length == 0)
        return Nullable!string.init;

    auto manifestDirectory = absolutePath(dirName(manifestPath));
    string resolved;
    if (isAbsoluteLike(entry))
        resolved = absolutePath(entry);
    else
        resolved = absolutePath(buildPath(manifestDirectory, entry));

    if (allowOutsidePluginDirectory || pathIsWithin(manifestDirectory, resolved))
        return Nullable!string.of(resolved);

    return Nullable!string.init;
}

private string relativeOrOriginal(string path, string rootDirectory)
{
    if (rootDirectory.length == 0)
        return path;
    return relativePath(path, absolutePath(rootDirectory));
}

private string jsonStringValue(JSONValue root, string key)
{
    auto value = root.object.get(key, JSONValue.init);
    if (value.type == JSONType.string)
        return value.str;
    return "";
}

private bool pathIsWithin(string root, string path)
{
    auto relative = relativePath(path, root);
    if (relative.length == 0 || relative == ".")
        return true;
    return !relative.startsWith("..") && !relative.startsWith("../") && !relative.startsWith("..\\");
}

private Nullable!LuaCapability parseCapability(string value)
{
    switch (value)
    {
        case "context.read":
            return Nullable!LuaCapability.of(LuaCapability.ContextRead);
        case "discord.reply":
            return Nullable!LuaCapability.of(LuaCapability.DiscordReply);
        case "state.read":
            return Nullable!LuaCapability.of(LuaCapability.StateRead);
        case "state.write":
            return Nullable!LuaCapability.of(LuaCapability.StateWrite);
        case "http":
            return Nullable!LuaCapability.of(LuaCapability.Http);
        case "log.write":
            return Nullable!LuaCapability.of(LuaCapability.LogWrite);
        default:
            return Nullable!LuaCapability.init;
    }
}

private LuaCapability[] effectivePermissions(PluginDescriptor descriptor, PluginSecurityPolicy security)
{
    if (descriptor.permissions.length != 0)
        return descriptor.permissions;

    // UDA-backed plugin descriptors are authored in trusted D code; keep legacy behavior.
    if (!descriptor.typeName.startsWith("lua:"))
        return allLuaCapabilities();

    if (descriptor.sandbox == LuaSandboxProfile.Trusted)
        return allLuaCapabilities();

    if (security.requireDeclaredPermissionsForUntrusted)
        return [];

    // Default minimal capability set for undeclared untrusted plugins.
    return [LuaCapability.ContextRead];
}

private string sandboxLabel(LuaSandboxProfile profile)
{
    return profile == LuaSandboxProfile.Trusted ? "trusted" : "untrusted";
}

private bool isAbsoluteLike(string path)
{
    if (path.length == 0)
        return false;

    return path[0] == '/' || path.canFind(":\\");
}

unittest
{
    @LuaPlugin("counter", entrypoint: "counter.lua", sandbox: LuaSandboxProfile.Untrusted)
    struct CounterPlugin
    {
    }

    auto registry = new PluginRegistry;
    registry.register!CounterPlugin();

    assert(registry.registeredNames == ["counter"]);
    assert(registry.find("counter").get.entrypoint == "counter.lua");

    auto descriptor = registry.find("counter").get;
    auto permissions = effectivePermissions(descriptor, PluginSecurityPolicy.init);
    assert(permissions.length == allLuaCapabilities.length);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.string : endsWith;

    auto root = "plugins-unittest";
    scope(exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    mkdirRecurse(buildPath(root, "counter"));
    write(
        buildPath(root, "counter", "plugin.json"),
        `{"name":"counter","version":"1.0.0","ddiscordApiVersion":"2","scripts":["main.lua"],"permissions":["state.read","state.write","log.write"],"sandbox":"trusted"}`
    );
    write(
        buildPath(root, "counter", "main.lua"),
        "function onLoad() state_set('status', 'loaded') end\nfunction onEnable() state_set('status', 'enabled') end\n"
    );
    write(buildPath(root, "loose.lua"), "-- loose");

    auto registry = new PluginRegistry;
    registry.loadAll(root);

    bool sawLoose;
    foreach (descriptor; registry.descriptors)
    {
        if (descriptor.entrypoint.endsWith("loose.lua"))
            sawLoose = true;
    }

    assert(registry.find("counter").get.sandbox == LuaSandboxProfile.Trusted);
    assert(registry.find("counter").get.permissions.length == 3);
    assert(sawLoose);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;

    auto root = "plugins-no-loose-unittest";
    scope(exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    mkdirRecurse(buildPath(root, "counter"));
    write(
        buildPath(root, "counter", "plugin.json"),
        `{"name":"counter","ddiscordApiVersion":"2","scripts":["main.lua"]}`
    );
    write(buildPath(root, "counter", "main.lua"), "function onEnable() end\n");
    write(buildPath(root, "loose.lua"), "function onEnable() end\n");

    auto registry = new PluginRegistry;
    registry.security.allowLooseScripts = false;
    registry.loadAll(root);

    assert(!registry.find("counter").isNull);
    assert(registry.find("loose.lua").isNull);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;

    auto root = "plugins-runtime-unittest";
    scope(exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    mkdirRecurse(buildPath(root, "counter"));
    write(
        buildPath(root, "counter", "plugin.json"),
        `{"name":"counter","ddiscordApiVersion":"2","scripts":["main.lua"],"permissions":["state.read","state.write"]}`
    );
    write(
        buildPath(root, "counter", "main.lua"),
        "function onLoad() state_set('status', 'loaded') end\nfunction onEnable() state_set('status', 'enabled') end\n"
    );

    auto registry = new PluginRegistry;
    registry.loadAll(root);

    auto state = new StateStore;
    auto scripting = new ScriptingEngine;
    registry.activateAll(scripting, state);

    assert(registry.runtimeStates.length == 1);
    assert(registry.runtimeStates[0].enabled);
    assert(state.global.get!string("plugin:counter:status") == "enabled");
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;

    auto root = "plugins-default-permissions-unittest";
    scope(exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    mkdirRecurse(buildPath(root, "minimal"));
    write(
        buildPath(root, "minimal", "plugin.json"),
        `{"name":"minimal","ddiscordApiVersion":"2","scripts":["main.lua"]}`
    );
    write(
        buildPath(root, "minimal", "main.lua"),
        "function onEnable() if state_set then state_set('status', 'enabled') end end\n"
    );

    auto registry = new PluginRegistry;
    registry.loadAll(root);
    auto descriptor = registry.find("minimal").get;
    auto permissions = effectivePermissions(descriptor, PluginSecurityPolicy.init);
    assert(permissions.length == 1);
    assert(permissions[0] == LuaCapability.ContextRead);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;

    auto root = "plugins-strict-permissions-unittest";
    scope(exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    mkdirRecurse(buildPath(root, "minimal"));
    write(
        buildPath(root, "minimal", "plugin.json"),
        `{"name":"minimal","ddiscordApiVersion":"2","scripts":["main.lua"]}`
    );
    write(buildPath(root, "minimal", "main.lua"), "function onEnable() end\n");

    auto registry = new PluginRegistry;
    registry.security.requireDeclaredPermissionsForUntrusted = true;
    registry.loadAll(root);
    auto descriptor = registry.find("minimal").get;
    auto permissions = effectivePermissions(descriptor, registry.security);
    assert(permissions.length == 0);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;

    auto root = "plugins-entrypoint-path-unittest";
    scope(exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    mkdirRecurse(buildPath(root, "sample"));
    write(
        buildPath(root, "sample", "plugin.json"),
        `{"name":"sample","ddiscordApiVersion":"2","entrypoint":"../outside.lua"}`
    );
    write(buildPath(root, "outside.lua"), "function onEnable() end\n");

    auto registry = new PluginRegistry;
    registry.loadAll(root);
    assert(registry.find("sample").isNull);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;

    auto root = "plugins-entrypoint-optout-unittest";
    scope(exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    mkdirRecurse(buildPath(root, "sample"));
    write(
        buildPath(root, "sample", "plugin.json"),
        `{"name":"sample","ddiscordApiVersion":"2","entrypoint":"../outside.lua"}`
    );
    write(buildPath(root, "outside.lua"), "function onEnable() end\n");

    auto registry = new PluginRegistry;
    registry.security.allowEntrypointOutsidePluginDirectory = true;
    registry.loadAll(root);
    assert(!registry.find("sample").isNull);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.string : endsWith;

    @LuaPlugin("counter", entrypoint: "counter.lua", sandbox: LuaSandboxProfile.Untrusted)
    struct HostCounterPlugin
    {
    }

    auto root = "plugins-merge-unittest";
    scope(exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    mkdirRecurse(buildPath(root, "counter"));
    write(
        buildPath(root, "counter", "plugin.json"),
        `{"name":"counter","ddiscordApiVersion":"2","scripts":["main.lua"]}`
    );
    write(buildPath(root, "counter", "main.lua"), "function onEnable() end\n");

    auto registry = new PluginRegistry;
    registry.register!HostCounterPlugin();
    registry.loadAll(root);

    assert(registry.find("counter").get.resolvedEntrypoint.endsWith("main.lua"));
}
