/**
 * ddiscord — plugin registry and runtime.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.plugins;

import ddiscord.scripting : LuaCapability, LuaExpose, LuaRuntime, LuaSandboxProfile, ScriptingEngine;
import ddiscord.state : StateStore;
import ddiscord.util.errors : formatError;
import ddiscord.util.optional : Nullable;
import std.algorithm : canFind;
import std.file : SpanMode, dirEntries, exists, isDir, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath, dirName, extension, relativePath;

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
    LuaSandboxProfile sandbox;
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

private struct PluginHostApi
{
    string pluginName;
    StateStore state;

    @LuaExpose("plugin_name", LuaCapability.ContextRead)
    string pluginNameValue()
    {
        return pluginName;
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

        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            if (!entry.isDir && baseName(entry.name) == "plugin.json")
                loadManifest(entry.name, directory);
        }
        foreach (entry; dirEntries(directory, SpanMode.depth))
        {
            if (entry.isDir || baseName(entry.name) != "plugin.json")
                continue;
            loadManifest(entry.name, directory);
        }

        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            if (!entry.isDir && extension(entry.name) == ".lua")
                loadLooseScript(entry.name, directory);
        }
        foreach (entry; dirEntries(directory, SpanMode.depth))
        {
            if (entry.isDir || extension(entry.name) != ".lua")
                continue;
            loadLooseScript(entry.name, directory);
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
                _loaded ~= loaded;
                continue;
            }

            auto runtime = scripting.open!PluginHostApi(
                PluginHostApi(descriptor.pluginName, state),
                descriptor.sandbox,
                descriptor.permissions
            );

            auto evalResult = runtime.evalFile(descriptor.resolvedEntrypoint);
            if (evalResult.isErr)
            {
                auto message = formatError(
                    "plugins",
                    "A Lua plugin failed during file evaluation.",
                    "Plugin `" ~ descriptor.pluginName ~ "` raised: " ~ evalResult.error.message,
                    "Fix the script syntax/runtime error; the plugin stayed disabled and the bot kept running."
                );
                loaded.lastError = Nullable!string.of(message);
                _loadErrors ~= message;
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
                continue;
            }

            if (callLifecycleHook(loaded, "onDisable") && loaded.runtime.hasCallable("onUnload"))
                callLifecycleHook(loaded, "onUnload");

            loaded.enabled = false;
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
            auto message = formatError(
                "plugins",
                "A Lua plugin failed during lifecycle execution.",
                "Plugin `" ~ loaded.descriptor.pluginName ~ "` hook `" ~ hookName ~ "` raised: " ~ result.error.message,
                "Fix the script hook or remove it; the failing plugin was isolated."
            );
            loaded.lastError = Nullable!string.of(message);
            _loadErrors ~= message;
            return false;
        }

        loaded.lifecycleHooks ~= hookName;
        return true;
    }

    private void loadManifest(string manifestPath, string rootDirectory)
    {
        JSONValue json;
        try
            json = parseJSON(readText(manifestPath));
        catch (Exception error)
        {
            _loadErrors ~= formatError(
                "plugins",
                "A plugin manifest could not be parsed as JSON.",
                "Manifest `" ~ manifestPath ~ "` failed with: " ~ error.msg,
                "Fix the JSON syntax before starting the bot again."
            );
            return;
        }

        PluginDescriptor descriptor;
        descriptor.typeName = "lua:" ~ manifestPath;

        auto nameValue = json.object.get("name", JSONValue.init);
        if (nameValue.type != JSONType.null_)
            descriptor.pluginName = nameValue.str;

        auto versionValue = json.object.get("version", JSONValue.init);
        if (versionValue.type != JSONType.null_)
            descriptor.pluginVersion = versionValue.str;

        auto apiVersionValue = json.object.get("ddiscordApiVersion", JSONValue.init);
        if (apiVersionValue.type != JSONType.null_)
            descriptor.apiVersion = apiVersionValue.str;

        auto sandboxValue = json.object.get("sandbox", JSONValue.init);
        if (sandboxValue.type != JSONType.null_ && sandboxValue.str == "trusted")
            descriptor.sandbox = LuaSandboxProfile.Trusted;

        auto permissionsValue = json.object.get("permissions", JSONValue.init);
        if (permissionsValue.type == JSONType.array)
        {
            foreach (item; permissionsValue.array)
            {
                auto permission = parseCapability(item.str);
                if (!permission.isNull)
                    descriptor.permissions ~= permission.get;
            }
        }

        auto scriptsValue = json.object.get("scripts", JSONValue.init);
        if (scriptsValue.type == JSONType.array && scriptsValue.array.length != 0)
        {
            auto entry = scriptsValue.array[0].str;
            descriptor.entrypoint = relativeOrOriginal(resolveScriptPath(entry, manifestPath), rootDirectory);
            descriptor.resolvedEntrypoint = resolveScriptPath(entry, manifestPath);
        }

        auto entrypointValue = json.object.get("entrypoint", JSONValue.init);
        if (descriptor.entrypoint.length == 0 && entrypointValue.type != JSONType.null_)
        {
            auto entry = entrypointValue.str;
            descriptor.entrypoint = relativeOrOriginal(resolveScriptPath(entry, manifestPath), rootDirectory);
            descriptor.resolvedEntrypoint = resolveScriptPath(entry, manifestPath);
        }

        if (descriptor.pluginName.length == 0)
            descriptor.pluginName = baseName(dirName(manifestPath));

        if (descriptor.entrypoint.length == 0)
        {
            auto fallback = buildPath(dirName(manifestPath), "main.lua");
            descriptor.entrypoint = relativeOrOriginal(fallback, rootDirectory);
            descriptor.resolvedEntrypoint = fallback;
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

private string resolveScriptPath(string entry, string manifestPath)
{
    if (isAbsoluteLike(entry))
        return absolutePath(entry);
    return absolutePath(buildPath(dirName(manifestPath), entry));
}

private string relativeOrOriginal(string path, string rootDirectory)
{
    if (rootDirectory.length == 0)
        return path;
    return relativePath(path, absolutePath(rootDirectory));
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
        default:
            return Nullable!LuaCapability.init;
    }
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
        `{"name":"counter","version":"1.0.0","ddiscordApiVersion":"2","scripts":["main.lua"],"permissions":["state.read","state.write"],"sandbox":"trusted"}`
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
    assert(registry.find("counter").get.permissions.length == 2);
    assert(sawLoose);
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
