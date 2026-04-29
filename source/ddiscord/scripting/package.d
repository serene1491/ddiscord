/**
 * ddiscord — scripting API surface.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.scripting;

import core.time : Duration, MonoTime, dur;
import ddiscord.scripting.lua54;
import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.result : Result;
import std.algorithm : canFind;
import std.array : join;
import std.conv : ConvException, to;
import std.string : indexOf, toStringz;
import std.traits : Parameters, ReturnType, Unqual, isCallable, isFloatingPoint, isIntegral;

/// Capability flags for Lua host APIs.
enum LuaCapability
{
    ContextRead,
    DiscordReply,
    StateRead,
    StateWrite,
    Http,
    LogWrite,
}

/// Sandbox profiles for Lua execution.
enum LuaSandboxProfile
{
    Trusted,
    Untrusted,
}

/// UDA that marks a function or method as Lua-visible.
struct LuaExpose
{
    string name;
    LuaCapability permission = LuaCapability.ContextRead;
    LuaExposeMode mode = LuaExposeMode.Function;
    LuaValueMutability valueMutability = LuaValueMutability.Auto;

    this(
        string name,
        LuaCapability permission = LuaCapability.ContextRead,
        LuaExposeMode mode = LuaExposeMode.Function,
        LuaValueMutability valueMutability = LuaValueMutability.Auto
    )
    {
        this.name = name;
        this.permission = permission;
        this.mode = mode;
        this.valueMutability = valueMutability;
    }
}


/// Export mode for `@LuaExpose` targets.
enum LuaExposeMode
{
    Function,
    Value,
}

/// Mutability policy for value-mode Lua exports.
enum LuaValueMutability
{
    Auto,
    Mutable,
    ReadOnly,
}


/// UDA that configures a namespaced Lua API table for a binding type.
struct LuaApi
{
    string namespaceName = DefaultLuaApiNamespace;
    bool exportGlobals = true;
}

enum DefaultLuaApiNamespace = "api";
enum LuaReadOnlyValueError = "Lua value export is readonly.";

/// Error returned by script execution.
struct ScriptError
{
    string message;
    size_t line;
}

private enum DefaultLuaInstructionCheckInterval = 25_000;
private enum DefaultLuaMemoryLimitBytes = 32 * 1024 * 1024;
private enum DefaultLuaExecutionTimeout = dur!"seconds"(2);

/// Runtime execution limits for the Lua sandbox.
struct LuaRuntimeLimits
{
    Duration maxExecutionTime = DefaultLuaExecutionTimeout;
    size_t maxMemoryBytes = DefaultLuaMemoryLimitBytes;
    uint instructionCheckInterval = DefaultLuaInstructionCheckInterval;
}

/// Metadata for a single exported Lua symbol.
struct LuaExportDescriptor
{
    string symbolName;
    string exportName;
    string hostSignature;
    LuaCapability permission;
    LuaExposeMode mode = LuaExposeMode.Function;
    LuaValueMutability valueMutability = LuaValueMutability.Auto;
    bool readonlyValue;
}

/// State reported after stepping a coroutine-backed Lua runtime.
enum LuaStepState
{
    Completed,
    Yielded,
}

/// Step payload returned by `evalStep*`, `callStep*`, and `resumeStep*`.
struct LuaStepResult
{
    LuaStepState state = LuaStepState.Completed;
    LuaValue value;

    bool completed() const @property
    {
        return state == LuaStepState.Completed;
    }

    bool yielded() const @property
    {
        return state == LuaStepState.Yielded;
    }
}

/// Safe Lua table projection.
struct LuaTable
{
    string[string] values;

    /// Creates a simple string-backed safe table.
    static LuaTable safe(Args...)(Args args)
        if (Args.length % 2 == 0)
    {
        LuaTable table;

        static foreach (index; 0 .. Args.length / 2)
        {
            {
                enum keyIndex = index * 2;
                enum valueIndex = keyIndex + 1;
                table.values[args[keyIndex]] = args[valueIndex];
            }
        }

        return table;
    }

    /// Renders the table in a developer-friendly Lua-ish format.
    string toDisplayString() const
    {
        string[] parts;
        foreach (key, value; values)
            parts ~= key ~ "=" ~ value;
        return "{" ~ parts.join(", ") ~ "}";
    }
}

/// Scalar or structured value crossing the Lua boundary.
struct LuaValue
{
    enum Kind
    {
        Nil,
        String,
        Integer,
        Number,
        Boolean,
        Table,
    }

    Kind kind = Kind.Nil;
    string stringValue;
    long integerValue;
    double numberValue;
    bool booleanValue;
    LuaTable tableValue;

    static LuaValue nil()
    {
        return LuaValue.init;
    }

    static LuaValue from(string value)
    {
        LuaValue result;
        result.kind = Kind.String;
        result.stringValue = value;
        return result;
    }

    static LuaValue from(long value)
    {
        LuaValue result;
        result.kind = Kind.Integer;
        result.integerValue = value;
        return result;
    }

    static LuaValue from(double value)
    {
        LuaValue result;
        result.kind = Kind.Number;
        result.numberValue = value;
        return result;
    }

    static LuaValue from(bool value)
    {
        LuaValue result;
        result.kind = Kind.Boolean;
        result.booleanValue = value;
        return result;
    }

    static LuaValue from(LuaTable value)
    {
        LuaValue result;
        result.kind = Kind.Table;
        result.tableValue = value;
        return result;
    }

    string toDisplayString() const
    {
        final switch (kind)
        {
            case Kind.Nil:
                return "nil";
            case Kind.String:
                return stringValue;
            case Kind.Integer:
                return integerValue.to!string;
            case Kind.Number:
                return numberValue.to!string;
            case Kind.Boolean:
                return booleanValue ? "true" : "false";
            case Kind.Table:
                return tableValue.toDisplayString();
        }
    }
}

private struct LuaCallableDescriptor
{
    string symbolName;
    string exportName;
    string hostSignature;
    LuaCapability permission;
    LuaExposeMode mode = LuaExposeMode.Function;
    Result!(LuaValue, ScriptError) delegate(LuaValue[]) invoke;
}

private struct LuaValueDescriptor
{
    string symbolName;
    string exportName;
    string hostSignature;
    LuaCapability permission;
    LuaExposeMode mode = LuaExposeMode.Value;
    LuaValueMutability valueMutability = LuaValueMutability.Auto;
    bool readonlyValue;
    Result!(LuaValue, ScriptError) delegate() read;
}

private struct LuaCollectedExports
{
    LuaCallableDescriptor[] callables;
    LuaValueDescriptor[] values;
}

private struct LuaApiDescriptor
{
    bool enabled;
    string namespaceName = DefaultLuaApiNamespace;
    bool exportGlobals = true;
}

private final class LuaCallableThunk
{
    string exportName;
    Result!(LuaValue, ScriptError) delegate(LuaValue[]) invoke;

    this(
        string exportName,
        Result!(LuaValue, ScriptError) delegate(LuaValue[]) invoke
    )
    {
        this.exportName = exportName;
        this.invoke = invoke;
    }
}

private final class LuaVm
{
    private lua_State* _state;
    private LuaSandboxProfile _profile;
    private LuaRuntimeLimits _limits;
    private LuaCallableThunk[] _thunks;
    private LuaCapability[string] _restrictedExports;
    private lua_State* _thread;
    private int _threadRef = LuaNoRef;
    private bool _suspended;
    private string _suspendedChunkName;
    private MonoTime _executionDeadline;

    this(
        LuaSandboxProfile profile,
        LuaCallableDescriptor[] callables,
        LuaValueDescriptor[] values = null,
        LuaApiDescriptor apiDescriptor = LuaApiDescriptor.init,
        LuaExportDescriptor[] restrictedExports = null,
        LuaRuntimeLimits limits = LuaRuntimeLimits.init
    )
    {
        _profile = profile;
        _limits = limits;
        if (_limits.maxExecutionTime <= Duration.zero)
            _limits.maxExecutionTime = DefaultLuaExecutionTimeout;
        if (_limits.maxMemoryBytes == 0)
            _limits.maxMemoryBytes = DefaultLuaMemoryLimitBytes;
        if (_limits.instructionCheckInterval == 0)
            _limits.instructionCheckInterval = DefaultLuaInstructionCheckInterval;

        _state = luaL_newstate();
        if (_state is null)
        {
            throw new DdiscordException(formatError(
                "scripting",
                "Could not create a Lua runtime.",
                "",
                "Verify that `liblua5.4` is installed and linkable on this system."
            ));
        }

        foreach (descriptor; restrictedExports)
        {
            _restrictedExports[descriptor.exportName] = descriptor.permission;
            auto rootName = luaExportRootName(descriptor.exportName);
            if (rootName.length != 0 && !(rootName in _restrictedExports))
                _restrictedExports[rootName] = descriptor.permission;
        }

        luaL_openlibs(_state);
        applySandbox();
        registerCallables(callables, apiDescriptor);
        registerValues(values, apiDescriptor);
    }

    ~this()
    {
        cancelSuspension();
        if (_state !is null)
            lua_close(_state);
        _state = null;
    }

    Result!(LuaValue, ScriptError) evalValue(string code)
    {
        auto step = evalStepValue(code);
        if (step.isErr)
            return Result!(LuaValue, ScriptError).err(step.error);
        if (step.value.yielded)
            return Result!(LuaValue, ScriptError).err(yieldedUnsupported("[eval]"));
        return Result!(LuaValue, ScriptError).ok(step.value.value);
    }

    Result!(LuaValue, ScriptError) evalFileValue(string path)
    {
        auto step = evalFileStepValue(path);
        if (step.isErr)
            return Result!(LuaValue, ScriptError).err(step.error);
        if (step.value.yielded)
            return Result!(LuaValue, ScriptError).err(yieldedUnsupported(path));
        return Result!(LuaValue, ScriptError).ok(step.value.value);
    }

    Result!(LuaValue, ScriptError) callValue(string globalName, LuaValue[] args = null)
    {
        auto step = callStepValue(globalName, args);
        if (step.isErr)
            return Result!(LuaValue, ScriptError).err(step.error);
        if (step.value.yielded)
            return Result!(LuaValue, ScriptError).err(yieldedUnsupported(globalName));
        return Result!(LuaValue, ScriptError).ok(step.value.value);
    }

    bool hasCallable(string globalName)
    {
        lua_getglobal(_state, toStringz(globalName));
        scope(exit) luaPop(_state, 1);
        return lua_type(_state, -1) == LuaTypeFunction;
    }

    bool canResume() const @property
    {
        return _suspended && _thread !is null;
    }

    void cancelSuspension()
    {
        releaseThread();
    }

    Result!(LuaStepResult, ScriptError) evalStepValue(string code)
    {
        if (_suspended)
        {
            return Result!(LuaStepResult, ScriptError).err(ScriptError(
                "Lua runtime has a suspended coroutine. Resume or cancel it before starting a new script.",
                0
            ));
        }

        auto chunkName = "[eval]";
        auto thread = beginThread(chunkName);
        auto status = luaL_loadstring(thread, toStringz(code));
        if (status != LuaOk)
            return loadErrorFromThread(thread, chunkName);

        return resumeThread(cast(int) 0, chunkName);
    }

    Result!(LuaStepResult, ScriptError) evalFileStepValue(string path)
    {
        if (_suspended)
        {
            return Result!(LuaStepResult, ScriptError).err(ScriptError(
                "Lua runtime has a suspended coroutine. Resume or cancel it before starting a new script.",
                0
            ));
        }

        auto thread = beginThread(path);
        auto status = luaL_loadfilex(thread, toStringz(path), null);
        if (status != LuaOk)
            return loadErrorFromThread(thread, path);

        return resumeThread(cast(int) 0, path);
    }

    Result!(LuaStepResult, ScriptError) callStepValue(string globalName, LuaValue[] args = null)
    {
        if (_suspended)
        {
            return Result!(LuaStepResult, ScriptError).err(ScriptError(
                "Lua runtime has a suspended coroutine. Resume or cancel it before starting a new call.",
                0
            ));
        }

        auto thread = beginThread(globalName);
        lua_getglobal(thread, toStringz(globalName));

        auto globalType = lua_type(thread, -1);
        if (globalType == LuaTypeNil)
        {
            lua_settop(thread, 0);
            releaseThread();
            return Result!(LuaStepResult, ScriptError).err(ScriptError(
                "Lua global `" ~ globalName ~ "` does not exist in this runtime.",
                0
            ));
        }

        if (globalType != LuaTypeFunction)
        {
            lua_settop(thread, 0);
            releaseThread();
            return Result!(LuaStepResult, ScriptError).err(ScriptError(
                "Lua global `" ~ globalName ~ "` exists but is not callable.",
                0
            ));
        }

        foreach (arg; args)
            pushValue(thread, arg);

        return resumeThread(cast(int) args.length, globalName);
    }

    Result!(LuaStepResult, ScriptError) resumeStepValue(LuaValue[] args = null)
    {
        if (!canResume)
        {
            return Result!(LuaStepResult, ScriptError).err(ScriptError(
                "Lua runtime does not have a suspended coroutine to resume.",
                0
            ));
        }

        foreach (arg; args)
            pushValue(_thread, arg);

        return resumeThread(cast(int) args.length, _suspendedChunkName);
    }

    private void applySandbox()
    {
        removeGlobal("dofile");
        removeGlobal("loadfile");
        removeGlobal("require");
        removeGlobal("io");
        removeGlobal("package");
        removeGlobal("debug");
        removeGlobal("os");

        if (_profile == LuaSandboxProfile.Untrusted)
        {
            removeGlobal("load");
            removeGlobal("collectgarbage");
            removeGlobal("getmetatable");
            removeGlobal("setmetatable");
            removeGlobal("rawget");
            removeGlobal("rawset");
            removeGlobal("rawequal");
            removeGlobal("rawlen");
        }
    }

    private void registerCallables(LuaCallableDescriptor[] callables, LuaApiDescriptor apiDescriptor)
    {
        auto apiTableIndex = ensureApiTable(apiDescriptor);
        scope(exit)
        {
            if (apiTableIndex != 0)
                luaPop(_state, 1);
        }

        foreach (callable; callables)
        {
            auto thunk = new LuaCallableThunk(callable.exportName, callable.invoke);
            _thunks ~= thunk;

            if (!apiDescriptor.enabled || apiDescriptor.exportGlobals)
            {
                setGlobalExport(callable.exportName, () {
                    pushCallable(thunk);
                });
            }

            if (apiTableIndex != 0)
            {
                setTableExport(apiTableIndex, callable.exportName, () {
                    pushCallable(thunk);
                });
            }
        }
    }

    private void registerValues(LuaValueDescriptor[] values, LuaApiDescriptor apiDescriptor)
    {
        auto apiTableIndex = ensureApiTable(apiDescriptor);
        scope(exit)
        {
            if (apiTableIndex != 0)
                luaPop(_state, 1);
        }

        foreach (valueDescriptor; values)
        {
            auto resolved = valueDescriptor.read();
            if (resolved.isErr)
            {
                throw new DdiscordException(formatError(
                    "scripting",
                    "Could not expose a Lua value export.",
                    resolved.error.message,
                    "Check the exported symbol type and Lua value conversion support."
                ));
            }

            if (!apiDescriptor.enabled || apiDescriptor.exportGlobals)
            {
                setGlobalExport(valueDescriptor.exportName, () {
                    pushExportedValue(_state, resolved.value, valueDescriptor.readonlyValue);
                });
            }

            if (apiTableIndex != 0)
            {
                setTableExport(apiTableIndex, valueDescriptor.exportName, () {
                    pushExportedValue(_state, resolved.value, valueDescriptor.readonlyValue);
                });
            }
        }
    }

    private void setGlobalExport(string exportPath, void delegate() pushExport)
    {
        auto path = splitLuaExportPath(exportPath);
        if (path.length == 0)
            return;

        if (path.length == 1)
        {
            pushExport();
            lua_setglobal(_state, toStringz(path[0]));
            return;
        }

        auto stackTop = lua_gettop(_state);
        scope(exit) lua_settop(_state, stackTop);

        auto rootTableIndex = ensureGlobalTable(path[0]);
        auto parentIndex = ensureNestedTablePath(rootTableIndex, path[1 .. $ - 1]);
        pushExport();
        lua_setfield(_state, parentIndex, toStringz(path[$ - 1]));
    }

    private void setTableExport(int tableIndex, string exportPath, void delegate() pushExport)
    {
        auto path = splitLuaExportPath(exportPath);
        if (path.length == 0)
            return;

        if (path.length == 1)
        {
            pushExport();
            lua_setfield(_state, tableIndex, toStringz(path[0]));
            return;
        }

        auto stackTop = lua_gettop(_state);
        scope(exit) lua_settop(_state, stackTop);

        auto parentIndex = ensureNestedTablePath(tableIndex, path[0 .. $ - 1]);
        pushExport();
        lua_setfield(_state, parentIndex, toStringz(path[$ - 1]));
    }

    private int ensureGlobalTable(string name)
    {
        lua_getglobal(_state, toStringz(name));
        if (lua_type(_state, -1) == LuaTypeTable)
            return lua_absindex(_state, -1);

        luaPop(_state, 1);
        lua_createtable(_state, 0, 8);
        lua_setglobal(_state, toStringz(name));
        lua_getglobal(_state, toStringz(name));
        return lua_absindex(_state, -1);
    }

    private int ensureNestedTablePath(int rootTableIndex, string[] path)
    {
        auto currentIndex = rootTableIndex;
        foreach (segment; path)
        {
            lua_getfield(_state, currentIndex, toStringz(segment));
            if (lua_type(_state, -1) != LuaTypeTable)
            {
                luaPop(_state, 1);
                lua_createtable(_state, 0, 8);
                lua_setfield(_state, currentIndex, toStringz(segment));
                lua_getfield(_state, currentIndex, toStringz(segment));
            }
            currentIndex = lua_absindex(_state, -1);
        }

        return currentIndex;
    }

    private int ensureApiTable(LuaApiDescriptor apiDescriptor)
    {
        if (!apiDescriptor.enabled || apiDescriptor.namespaceName.length == 0)
            return 0;

        lua_getglobal(_state, toStringz(apiDescriptor.namespaceName));
        if (lua_type(_state, -1) == LuaTypeTable)
            return lua_absindex(_state, -1);

        luaPop(_state, 1);
        lua_createtable(_state, 0, 8);
        lua_setglobal(_state, toStringz(apiDescriptor.namespaceName));
        lua_getglobal(_state, toStringz(apiDescriptor.namespaceName));
        return lua_absindex(_state, -1);
    }

    private lua_State* beginThread(string chunkName)
    {
        releaseThread();

        _thread = lua_newthread(_state);
        _threadRef = luaL_ref(_state, LuaRegistryIndex);
        _suspended = false;
        _suspendedChunkName = chunkName;
        return _thread;
    }

    private Result!(LuaStepResult, ScriptError) loadErrorFromThread(lua_State* thread, string chunkName)
    {
        auto message = stackString(thread, -1);
        lua_settop(thread, 0);
        releaseThread();
        return Result!(LuaStepResult, ScriptError).err(scriptError(enrichLuaError(message), chunkName));
    }

    private Result!(LuaStepResult, ScriptError) resumeThread(int nargs, string chunkName)
    {
        auto thread = _thread;
        if (thread is null)
        {
            return Result!(LuaStepResult, ScriptError).err(ScriptError(
                "Lua runtime does not have an active coroutine.",
                0
            ));
        }

        _executionDeadline = MonoTime.currTime + _limits.maxExecutionTime;
        auto previousHookVm = _activeLuaVmForHook;
        _activeLuaVmForHook = this;
        auto hookInterval = _limits.instructionCheckInterval > cast(uint) int.max
            ? int.max
            : cast(int) _limits.instructionCheckInterval;
        if (hookInterval <= 0)
            hookInterval = cast(int) DefaultLuaInstructionCheckInterval;
        lua_sethook(thread, &enforceLuaRuntimeLimits, LuaMaskCount, hookInterval);
        scope(exit)
        {
            lua_sethook(thread, cast(lua_Hook) null, 0, 0);
            _activeLuaVmForHook = previousHookVm;
        }

        int nresults = 0;
        auto status = lua_resume(thread, _state, nargs, &nresults);

        if (status == LuaYield)
        {
            auto value = firstResultFromThread(thread, nresults);
            lua_settop(thread, 0);
            if (value.isErr)
            {
                releaseThread();
                return Result!(LuaStepResult, ScriptError).err(value.error);
            }

            _suspended = true;
            _suspendedChunkName = chunkName;

            LuaStepResult step;
            step.state = LuaStepState.Yielded;
            step.value = value.value;
            return Result!(LuaStepResult, ScriptError).ok(step);
        }

        if (status == LuaOk)
        {
            auto value = firstResultFromThread(thread, nresults);
            lua_settop(thread, 0);
            if (value.isErr)
            {
                releaseThread();
                return Result!(LuaStepResult, ScriptError).err(value.error);
            }

            LuaStepResult step;
            step.state = LuaStepState.Completed;
            step.value = value.value;
            releaseThread();
            return Result!(LuaStepResult, ScriptError).ok(step);
        }

        auto message = stackString(thread, -1);
        lua_settop(thread, 0);
        releaseThread();
        return Result!(LuaStepResult, ScriptError).err(scriptError(enrichLuaError(message), chunkName));
    }

    private Result!(LuaValue, ScriptError) firstResultFromThread(lua_State* thread, int nresults)
    {
        if (nresults <= 0)
            return Result!(LuaValue, ScriptError).ok(LuaValue.nil());

        return valueFromStack(thread, -nresults);
    }

    private string runtimeLimitViolation(lua_State* state)
    {
        if (MonoTime.currTime > _executionDeadline)
        {
            return "Lua execution exceeded time limit (`" ~
                _limits.maxExecutionTime.total!"msecs".to!string ~ "ms`).";
        }

        auto kilobytes = lua_gc(state, LuaGcCount, 0);
        auto bytesRemainder = lua_gc(state, LuaGcCountB, 0);
        if (kilobytes >= 0 && bytesRemainder >= 0)
        {
            auto totalBytes = cast(size_t) kilobytes * 1024 + cast(size_t) bytesRemainder;
            if (totalBytes > _limits.maxMemoryBytes)
            {
                return "Lua execution exceeded memory limit (`" ~
                    _limits.maxMemoryBytes.to!string ~ " bytes`, currently `" ~
                    totalBytes.to!string ~ "`).";
            }
        }

        return "";
    }

    private void releaseThread()
    {
        _suspended = false;
        _suspendedChunkName = "";
        _thread = null;

        if (_state is null)
            return;

        if (_threadRef != LuaNoRef)
            luaL_unref(_state, LuaRegistryIndex, _threadRef);
        _threadRef = LuaNoRef;
    }

    private ScriptError yieldedUnsupported(string chunkName)
    {
        return ScriptError(
            "Lua chunk `" ~ chunkName ~ "` yielded. Use `evalStep*`/`callStep*` plus `resumeStep*` to continue execution.",
            0
        );
    }

    private void pushCallable(LuaCallableThunk thunk)
    {
        lua_pushlightuserdata(_state, cast(void*) thunk);
        lua_pushcclosure(_state, &invokeLuaCallable, 1);
    }

    private void removeGlobal(string name)
    {
        lua_pushnil(_state);
        lua_setglobal(_state, toStringz(name));
    }

    private string lastErrorMessage(lua_State* state)
    {
        auto message = stackString(state, -1);
        luaPop(state, 1);
        return message;
    }

    private string enrichLuaError(string message)
    {
        if (_restrictedExports.length == 0)
            return message;

        auto missingGlobal = extractMissingGlobalName(message);
        if (missingGlobal.length == 0)
            return message;

        auto requiredCapability = missingGlobal in _restrictedExports;
        if (requiredCapability is null)
            return message;

        return message ~ " Hint: global `" ~ missingGlobal ~ "` requires capability `" ~
            luaCapabilityName(*requiredCapability) ~ "` in the runtime permissions list.";
    }

    private string extractMissingGlobalName(string message)
    {
        foreach (marker; [
            "attempt to call a nil value (global '",
            "attempt to index a nil value (global '",
            "attempt to index a function value (global '"
        ])
        {
            auto markerStart = message.indexOf(marker);
            if (markerStart == -1)
                continue;

            auto nameStart = cast(size_t) markerStart + marker.length;
            if (nameStart >= message.length)
                continue;

            auto tail = message[nameStart .. $];
            auto nameEnd = tail.indexOf("'");
            if (nameEnd == -1)
                continue;

            return tail[0 .. cast(size_t) nameEnd];
        }

        return "";
    }
}

private string[] splitLuaExportPath(string exportPath)
{
    if (exportPath.length == 0)
        return null;

    string[] segments;
    size_t segmentStart = 0;

    foreach (index; 0 .. exportPath.length + 1)
    {
        auto atBoundary = index == exportPath.length
            || (index < exportPath.length && exportPath[index] == '.');
        if (!atBoundary)
            continue;

        if (index == segmentStart)
            return [exportPath];

        segments ~= exportPath[segmentStart .. index];
        segmentStart = index + 1;
    }

    return segments;
}

private string luaExportRootName(string exportPath)
{
    auto path = splitLuaExportPath(exportPath);
    if (path.length == 0)
        return "";
    return path[0];
}

/// Execution-time runtime handle.
struct LuaRuntime
{
    LuaSandboxProfile profile;
    LuaCapability[] permissions;
    LuaRuntimeLimits limits;
    LuaExportDescriptor[] exports;
    LuaExportDescriptor[] restrictedExports;
    private LuaVm _vm;

    /// Evaluates a Lua snippet.
    Result!(string, ScriptError) eval(string code)
    {
        auto result = evalTyped(code);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.toDisplayString());
    }

    /// Evaluates Lua and returns the typed Lua value.
    Result!(LuaValue, ScriptError) evalTyped(string code)
    {
        if (code.length == 0)
            return Result!(LuaValue, ScriptError).err(ScriptError("empty script", 0));

        if (_vm is null)
            return Result!(LuaValue, ScriptError).err(ScriptError("runtime is not initialized", 0));

        return _vm.evalValue(code);
    }

    /// Evaluates Lua and returns either a completed value or a yielded payload.
    Result!(LuaStepResult, ScriptError) evalStepTyped(string code)
    {
        if (code.length == 0)
            return Result!(LuaStepResult, ScriptError).err(ScriptError("empty script", 0));

        if (_vm is null)
            return Result!(LuaStepResult, ScriptError).err(ScriptError("runtime is not initialized", 0));

        return _vm.evalStepValue(code);
    }

    /// Evaluates Lua and returns either a completed display value or yielded display payload.
    Result!(string, ScriptError) evalStep(string code)
    {
        auto result = evalStepTyped(code);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.value.toDisplayString());
    }

    /// Evaluates a Lua file from disk.
    Result!(string, ScriptError) evalFile(string path)
    {
        auto result = evalFileTyped(path);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.toDisplayString());
    }

    /// Evaluates a Lua file and returns the typed Lua value.
    Result!(LuaValue, ScriptError) evalFileTyped(string path)
    {
        if (path.length == 0)
            return Result!(LuaValue, ScriptError).err(ScriptError("empty path", 0));

        if (_vm is null)
            return Result!(LuaValue, ScriptError).err(ScriptError("runtime is not initialized", 0));

        return _vm.evalFileValue(path);
    }

    /// Evaluates a Lua file and returns either a completed value or yielded payload.
    Result!(LuaStepResult, ScriptError) evalFileStepTyped(string path)
    {
        if (path.length == 0)
            return Result!(LuaStepResult, ScriptError).err(ScriptError("empty path", 0));

        if (_vm is null)
            return Result!(LuaStepResult, ScriptError).err(ScriptError("runtime is not initialized", 0));

        return _vm.evalFileStepValue(path);
    }

    /// Evaluates a Lua file and returns either a completed display value or yielded display payload.
    Result!(string, ScriptError) evalFileStep(string path)
    {
        auto result = evalFileStepTyped(path);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.value.toDisplayString());
    }

    /// Calls an already-loaded global Lua function.
    Result!(string, ScriptError) call(string globalName, LuaValue[] args = null)
    {
        auto result = callTyped(globalName, args);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.toDisplayString());
    }

    /// Calls an already-loaded global Lua function and returns typed Lua data.
    Result!(LuaValue, ScriptError) callTyped(string globalName, LuaValue[] args = null)
    {
        if (globalName.length == 0)
            return Result!(LuaValue, ScriptError).err(ScriptError("empty function name", 0));

        if (_vm is null)
            return Result!(LuaValue, ScriptError).err(ScriptError("runtime is not initialized", 0));

        return _vm.callValue(globalName, args);
    }

    /// Calls an already-loaded global Lua function and returns either a completed value or yielded payload.
    Result!(LuaStepResult, ScriptError) callStepTyped(string globalName, LuaValue[] args = null)
    {
        if (globalName.length == 0)
            return Result!(LuaStepResult, ScriptError).err(ScriptError("empty function name", 0));

        if (_vm is null)
            return Result!(LuaStepResult, ScriptError).err(ScriptError("runtime is not initialized", 0));

        return _vm.callStepValue(globalName, args);
    }

    /// Calls an already-loaded global Lua function and returns either a completed display value or yielded payload.
    Result!(string, ScriptError) callStep(string globalName, LuaValue[] args = null)
    {
        auto result = callStepTyped(globalName, args);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.value.toDisplayString());
    }

    /// Resumes a suspended Lua coroutine with optional resume arguments.
    Result!(LuaStepResult, ScriptError) resumeStepTyped(LuaValue[] args = null)
    {
        if (_vm is null)
            return Result!(LuaStepResult, ScriptError).err(ScriptError("runtime is not initialized", 0));

        return _vm.resumeStepValue(args);
    }

    /// Resumes a suspended Lua coroutine with a single resume argument.
    Result!(LuaStepResult, ScriptError) resumeStepTyped(LuaValue arg)
    {
        LuaValue[1] args;
        args[0] = arg;
        return resumeStepTyped(args[]);
    }

    /// Resumes a suspended Lua coroutine with optional resume arguments and stringifies the payload.
    Result!(string, ScriptError) resumeStep(LuaValue[] args = null)
    {
        auto result = resumeStepTyped(args);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.value.toDisplayString());
    }

    /// Resumes a suspended Lua coroutine with a single resume argument and stringifies the payload.
    Result!(string, ScriptError) resumeStep(LuaValue arg)
    {
        auto result = resumeStepTyped(arg);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.value.toDisplayString());
    }

    /// Returns whether this runtime currently has a suspended coroutine.
    bool canResume() const @property
    {
        return _vm !is null && _vm.canResume;
    }

    /// Drops any suspended coroutine state.
    void cancelSuspension()
    {
        if (_vm is null)
            return;
        _vm.cancelSuspension();
    }

    /// Runs a yield-aware script and auto-resumes when yielded payloads are handled by host code.
    Result!(LuaValue, ScriptError) evalAutoResumeTyped(
        string code,
        Result!(LuaValue, string) delegate(LuaValue) onYield,
        size_t maxYields = 32
    )
    {
        auto step = evalStepTyped(code);
        return autoResumeStep(step, onYield, maxYields);
    }

    /// Runs a yield-aware script and stringifies the completed output.
    Result!(string, ScriptError) evalAutoResume(
        string code,
        Result!(LuaValue, string) delegate(LuaValue) onYield,
        size_t maxYields = 32
    )
    {
        auto result = evalAutoResumeTyped(code, onYield, maxYields);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);
        return Result!(string, ScriptError).ok(result.value.toDisplayString());
    }

    /// Calls a yield-aware Lua function and auto-resumes when yielded payloads are handled by host code.
    Result!(LuaValue, ScriptError) callAutoResumeTyped(
        string globalName,
        Result!(LuaValue, string) delegate(LuaValue) onYield,
        LuaValue[] args = null,
        size_t maxYields = 32
    )
    {
        auto step = callStepTyped(globalName, args);
        return autoResumeStep(step, onYield, maxYields);
    }

    /// Calls a yield-aware Lua function and stringifies the completed output.
    Result!(string, ScriptError) callAutoResume(
        string globalName,
        Result!(LuaValue, string) delegate(LuaValue) onYield,
        LuaValue[] args = null,
        size_t maxYields = 32
    )
    {
        auto result = callAutoResumeTyped(globalName, onYield, args, maxYields);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);
        return Result!(string, ScriptError).ok(result.value.toDisplayString());
    }

    /// Returns true when a yielded value contains a table field and outputs that string value.
    static bool yieldedTableField(LuaValue yielded, string field, out string value)
    {
        value = "";
        if (yielded.kind != LuaValue.Kind.Table || field.length == 0)
            return false;

        auto resolved = field in yielded.tableValue.values;
        if (resolved is null)
            return false;

        value = *resolved;
        return true;
    }

    /// Returns true when a yielded table contains a `kind` field and outputs it.
    static bool yieldedSignalKind(LuaValue yielded, out string kind)
    {
        return yieldedTableField(yielded, "kind", kind);
    }

    /// Returns whether a named Lua global exists and is callable.
    bool hasCallable(string globalName)
    {
        if (_vm is null || globalName.length == 0)
            return false;
        return _vm.hasCallable(globalName);
    }

    /// Returns the export names visible to this runtime.
    string[] exportNames() const @property
    {
        string[] names;
        foreach (descriptor; exports)
            names ~= descriptor.exportName;
        return names;
    }

    /// Returns whether a given export is available.
    bool hasExport(string name) const
    {
        foreach (descriptor; exports)
        {
            if (descriptor.exportName == name)
                return true;
        }

        return false;
    }

    /// Returns whether a given value export is available.
    bool hasValue(string name) const
    {
        foreach (descriptor; exports)
        {
            if (descriptor.mode == LuaExposeMode.Value && descriptor.exportName == name)
                return true;
        }
        return false;
    }

    /// Returns whether a value export is readonly in this runtime.
    bool valueExportReadOnly(string name) const
    {
        foreach (descriptor; exports)
        {
            if (descriptor.mode == LuaExposeMode.Value && descriptor.exportName == name)
                return descriptor.readonlyValue;
        }
        return false;
    }

    /// Returns export names visible as callable functions.
    string[] callableExportNames() const @property
    {
        string[] names;
        foreach (descriptor; exports)
        {
            if (descriptor.mode == LuaExposeMode.Function)
                names ~= descriptor.exportName;
        }
        return names;
    }

    /// Returns export names visible as direct values.
    string[] valueExportNames() const @property
    {
        string[] names;
        foreach (descriptor; exports)
        {
            if (descriptor.mode == LuaExposeMode.Value)
                names ~= descriptor.exportName;
        }
        return names;
    }

    private Result!(LuaValue, ScriptError) autoResumeStep(
        Result!(LuaStepResult, ScriptError) step,
        Result!(LuaValue, string) delegate(LuaValue) onYield,
        size_t maxYields
    )
    {
        if (step.isErr)
            return Result!(LuaValue, ScriptError).err(step.error);
        if (onYield is null)
            return Result!(LuaValue, ScriptError).err(ScriptError("Lua auto-resume handler must not be null.", 0));

        size_t iterations;
        auto current = step.value;
        while (current.yielded)
        {
            if (iterations >= maxYields)
            {
                return Result!(LuaValue, ScriptError).err(ScriptError(
                    "Lua auto-resume exceeded max yield count `" ~ maxYields.to!string ~ "`.",
                    0
                ));
            }

            auto resumedValue = onYield(current.value);
            if (resumedValue.isErr)
                return Result!(LuaValue, ScriptError).err(ScriptError(resumedValue.error, 0));

            auto resumed = resumeStepTyped(resumedValue.value);
            if (resumed.isErr)
                return Result!(LuaValue, ScriptError).err(resumed.error);

            current = resumed.value;
            iterations++;
        }

        return Result!(LuaValue, ScriptError).ok(current.value);
    }
}

private LuaVm _activeLuaVmForHook;

private extern (C) void enforceLuaRuntimeLimits(lua_State* state, lua_Debug* ar) @trusted
{
    auto _ = ar;

    if (_activeLuaVmForHook is null)
        return;

    auto violation = _activeLuaVmForHook.runtimeLimitViolation(state);
    if (violation.length == 0)
        return;

    lua_pushlstring(state, violation.ptr, violation.length);
    lua_error(state);
}

/// Minimal scripting engine surface.
final class ScriptingEngine
{
    /// Opens a runtime for a binding object.
    LuaRuntime open(T)(
        T binding,
        LuaSandboxProfile profile = LuaSandboxProfile.Untrusted,
        LuaCapability[] permissions = null,
        LuaRuntimeLimits limits = LuaRuntimeLimits.init
    )
    {
        if (limits.maxExecutionTime <= Duration.zero)
            limits.maxExecutionTime = DefaultLuaExecutionTimeout;
        if (limits.maxMemoryBytes == 0)
            limits.maxMemoryBytes = DefaultLuaMemoryLimitBytes;
        if (limits.instructionCheckInterval == 0)
            limits.instructionCheckInterval = DefaultLuaInstructionCheckInterval;

        auto box = new BindingBox!T(binding);
        auto collected = collectExports!T(box);
        auto apiDescriptor = collectLuaApiDescriptor!T();
        auto callables = materializeCallables(filterCallables(collected.callables, permissions), apiDescriptor);
        auto restrictedCallablesOnly = materializeCallables(
            restrictedCallables(collected.callables, permissions),
            apiDescriptor
        );
        auto values = materializeValues(filterValues(collected.values, permissions), apiDescriptor);
        auto restrictedValuesOnly = materializeValues(
            restrictedValues(collected.values, permissions),
            apiDescriptor
        );
        enforceUniqueExports(callables, values);

        LuaRuntime runtime;
        runtime.profile = profile;
        runtime.permissions = permissions.dup;
        runtime.limits = limits;
        runtime.exports = toExportDescriptors(callables, values);
        runtime.restrictedExports = toExportDescriptors(restrictedCallablesOnly, restrictedValuesOnly);
        runtime._vm = new LuaVm(
            profile,
            callables,
            values,
            LuaApiDescriptor.init,
            runtime.restrictedExports,
            limits
        );
        return runtime;
    }

    /// Opens one runtime from multiple binding objects and merges their Lua surfaces.
    LuaRuntime openMany(Bindings...)(
        Bindings bindings,
        LuaSandboxProfile profile = LuaSandboxProfile.Untrusted,
        LuaCapability[] permissions = null,
        LuaRuntimeLimits limits = LuaRuntimeLimits.init
    )
        if (Bindings.length > 0)
    {
        if (limits.maxExecutionTime <= Duration.zero)
            limits.maxExecutionTime = DefaultLuaExecutionTimeout;
        if (limits.maxMemoryBytes == 0)
            limits.maxMemoryBytes = DefaultLuaMemoryLimitBytes;
        if (limits.instructionCheckInterval == 0)
            limits.instructionCheckInterval = DefaultLuaInstructionCheckInterval;

        LuaCallableDescriptor[] callables;
        LuaCallableDescriptor[] restrictedCallablesOnly;
        LuaValueDescriptor[] values;
        LuaValueDescriptor[] restrictedValuesOnly;

        static foreach (index, BindingT; Bindings)
        {
            {
                auto box = new BindingBox!BindingT(bindings[index]);
                auto collected = collectExports!BindingT(box);
                auto apiDescriptor = collectLuaApiDescriptor!BindingT();

                callables ~= materializeCallables(filterCallables(collected.callables, permissions), apiDescriptor);
                restrictedCallablesOnly ~= materializeCallables(
                    restrictedCallables(collected.callables, permissions),
                    apiDescriptor
                );
                values ~= materializeValues(filterValues(collected.values, permissions), apiDescriptor);
                restrictedValuesOnly ~= materializeValues(
                    restrictedValues(collected.values, permissions),
                    apiDescriptor
                );
            }
        }

        enforceUniqueExports(callables, values);

        LuaRuntime runtime;
        runtime.profile = profile;
        runtime.permissions = permissions.dup;
        runtime.limits = limits;
        runtime.exports = toExportDescriptors(callables, values);
        runtime.restrictedExports = toExportDescriptors(restrictedCallablesOnly, restrictedValuesOnly);
        runtime._vm = new LuaVm(
            profile,
            callables,
            values,
            LuaApiDescriptor.init,
            runtime.restrictedExports,
            limits
        );
        return runtime;
    }
}

/// Returns every capability currently known by this build.
LuaCapability[] allLuaCapabilities()
{
    return [
        LuaCapability.ContextRead,
        LuaCapability.DiscordReply,
        LuaCapability.StateRead,
        LuaCapability.StateWrite,
        LuaCapability.Http,
        LuaCapability.LogWrite,
    ];
}

/// Returns the manifest-style name for a Lua capability.
string luaCapabilityName(LuaCapability capability)
{
    final switch (capability)
    {
        case LuaCapability.ContextRead:
            return "context.read";
        case LuaCapability.DiscordReply:
            return "discord.reply";
        case LuaCapability.StateRead:
            return "state.read";
        case LuaCapability.StateWrite:
            return "state.write";
        case LuaCapability.Http:
            return "http";
        case LuaCapability.LogWrite:
            return "log.write";
    }
}

private final class BindingBox(T)
{
    T value;

    this(T value)
    {
        this.value = value;
    }
}

private string sanitizeLuaIdentifier(string candidate, string fallback)
{
    if (!isLuaIdentifier(candidate))
        return fallback;
    return candidate;
}

private bool isLuaIdentifier(string text)
{
    if (text.length == 0)
        return false;
    if (!isLuaIdentifierStart(text[0]))
        return false;

    foreach (ch; text[1 .. $])
    {
        if (!isLuaIdentifierBody(ch))
            return false;
    }

    return true;
}

private bool isLuaIdentifierStart(char ch)
{
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_';
}

private bool isLuaIdentifierBody(char ch)
{
    return isLuaIdentifierStart(ch) || (ch >= '0' && ch <= '9');
}

private bool inferLuaValueReadOnly(T)()
{
    static if (is(Unqual!T == LuaTable))
        return typeHasConstQualifier!T || typeHasImmutableQualifier!T;
    else
        return false;
}

private bool typeHasConstQualifier(T)()
{
    return is(T == const U, U) || is(T == const shared U, U) || is(T == shared const U, U);
}

private bool typeHasImmutableQualifier(T)()
{
    return is(T == immutable U, U) || is(T == immutable shared U, U) || is(T == shared immutable U, U);
}

private bool resolveLuaValueReadOnly(LuaValueMutability mutability, bool inferred)
{
    final switch (mutability)
    {
        case LuaValueMutability.Auto:
            return inferred;
        case LuaValueMutability.Mutable:
            return false;
        case LuaValueMutability.ReadOnly:
            return true;
    }
}

private LuaCallableDescriptor[] filterCallables(
    LuaCallableDescriptor[] callables,
    LuaCapability[] permissions
)
{
    if (permissions.length == 0)
        return callables;

    LuaCallableDescriptor[] filtered;
    foreach (descriptor; callables)
    {
        if (permissions.canFind(descriptor.permission))
            filtered ~= descriptor;
    }
    return filtered;
}

private LuaValueDescriptor[] filterValues(
    LuaValueDescriptor[] values,
    LuaCapability[] permissions
)
{
    if (permissions.length == 0)
        return values;

    LuaValueDescriptor[] filtered;
    foreach (descriptor; values)
    {
        if (permissions.canFind(descriptor.permission))
            filtered ~= descriptor;
    }
    return filtered;
}

private LuaCallableDescriptor[] restrictedCallables(
    LuaCallableDescriptor[] callables,
    LuaCapability[] permissions
)
{
    if (permissions.length == 0)
        return null;

    LuaCallableDescriptor[] restricted;
    foreach (descriptor; callables)
    {
        if (!permissions.canFind(descriptor.permission))
            restricted ~= descriptor;
    }
    return restricted;
}

private LuaValueDescriptor[] restrictedValues(
    LuaValueDescriptor[] values,
    LuaCapability[] permissions
)
{
    if (permissions.length == 0)
        return null;

    LuaValueDescriptor[] restricted;
    foreach (descriptor; values)
    {
        if (!permissions.canFind(descriptor.permission))
            restricted ~= descriptor;
    }
    return restricted;
}

private LuaCallableDescriptor[] materializeCallables(
    LuaCallableDescriptor[] callables,
    LuaApiDescriptor apiDescriptor
)
{
    if (!apiDescriptor.enabled || apiDescriptor.namespaceName.length == 0)
        return callables.dup;

    LuaCallableDescriptor[] materialized;
    foreach (descriptor; callables)
    {
        if (apiDescriptor.exportGlobals)
            materialized ~= descriptor;

        auto namespaced = descriptor;
        namespaced.exportName = apiDescriptor.namespaceName ~ "." ~ descriptor.exportName;
        materialized ~= namespaced;
    }

    return materialized;
}

private LuaValueDescriptor[] materializeValues(
    LuaValueDescriptor[] values,
    LuaApiDescriptor apiDescriptor
)
{
    if (!apiDescriptor.enabled || apiDescriptor.namespaceName.length == 0)
        return values.dup;

    LuaValueDescriptor[] materialized;
    foreach (descriptor; values)
    {
        if (apiDescriptor.exportGlobals)
            materialized ~= descriptor;

        auto namespaced = descriptor;
        namespaced.exportName = apiDescriptor.namespaceName ~ "." ~ descriptor.exportName;
        materialized ~= namespaced;
    }

    return materialized;
}

private void enforceUniqueExports(
    LuaCallableDescriptor[] callables,
    LuaValueDescriptor[] values
)
{
    string[string] seen;

    foreach (callable; callables)
    {
        auto existing = callable.exportName in seen;
        if (existing !is null)
        {
            throw new DdiscordException(formatError(
                "scripting",
                "Duplicate Lua export names are not allowed.",
                "Export `" ~ callable.exportName ~ "` is declared by both `" ~ *existing ~
                    "` and `" ~ callable.symbolName ~ "`.",
                "Rename one of the exports or set explicit `@LuaExpose(\"name\")` values."
            ));
        }
        seen[callable.exportName] = callable.symbolName;
    }

    foreach (value; values)
    {
        auto existing = value.exportName in seen;
        if (existing !is null)
        {
            throw new DdiscordException(formatError(
                "scripting",
                "Duplicate Lua export names are not allowed.",
                "Export `" ~ value.exportName ~ "` is declared by both `" ~ *existing ~
                    "` and `" ~ value.symbolName ~ "`.",
                "Rename one of the exports or set explicit `@LuaExpose(\"name\")` values."
            ));
        }
        seen[value.exportName] = value.symbolName;
    }
}

private LuaExportDescriptor[] toExportDescriptors(
    LuaCallableDescriptor[] callables,
    LuaValueDescriptor[] values
)
{
    LuaExportDescriptor[] exports;

    foreach (callable; callables)
    {
        LuaExportDescriptor descriptor;
        descriptor.symbolName = callable.symbolName;
        descriptor.exportName = callable.exportName;
        descriptor.hostSignature = callable.hostSignature;
        descriptor.permission = callable.permission;
        descriptor.mode = LuaExposeMode.Function;
        descriptor.valueMutability = LuaValueMutability.Auto;
        descriptor.readonlyValue = false;
        exports ~= descriptor;
    }

    foreach (value; values)
    {
        LuaExportDescriptor descriptor;
        descriptor.symbolName = value.symbolName;
        descriptor.exportName = value.exportName;
        descriptor.hostSignature = value.hostSignature;
        descriptor.permission = value.permission;
        descriptor.mode = LuaExposeMode.Value;
        descriptor.valueMutability = value.valueMutability;
        descriptor.readonlyValue = value.readonlyValue;
        exports ~= descriptor;
    }

    return exports;
}

private LuaApiDescriptor collectLuaApiDescriptor(T)()
{
    LuaApiDescriptor descriptor;

    static foreach (attr; __traits(getAttributes, T))
    {
        static if (is(typeof(attr) == LuaApi))
        {
            descriptor.enabled = true;
            descriptor.namespaceName = sanitizeLuaIdentifier(attr.namespaceName, DefaultLuaApiNamespace);
            descriptor.exportGlobals = attr.exportGlobals;
        }
    }

    return descriptor;
}

private string hostCallableSignature(alias memberSymbol)(string memberName)
{
    alias ParamTypes = Parameters!memberSymbol;
    alias ReturnT = ReturnType!memberSymbol;

    string signature = ReturnT.stringof ~ " " ~ memberName ~ "(";
    static foreach (index, ParamT; ParamTypes)
    {
        static if (index != 0)
            signature ~= ", ";
        signature ~= ParamT.stringof ~ " arg" ~ (index + 1).to!string;
    }
    signature ~= ")";
    return signature;
}

private string hostValueSignature(alias memberSymbol)(string memberName)
{
    static if (isCallable!memberSymbol)
    {
        alias ReturnT = ReturnType!memberSymbol;
        return ReturnT.stringof ~ " " ~ memberName ~ "() [value]";
    }
    else
    {
        return memberSymbol.stringof ~ " " ~ memberName ~ " [value]";
    }
}

private LuaCollectedExports collectExports(T)(BindingBox!T box)
{
    LuaCollectedExports collected;

    static foreach (memberName; __traits(allMembers, T))
    {
        {
            static if (memberName != "__ctor" && memberName != "__xdtor")
            {
                mixin("alias memberSymbol = T." ~ memberName ~ ";");
                static foreach (attr; __traits(getAttributes, memberSymbol))
                {
                    static if (is(typeof(attr) == LuaExpose))
                    {
                        enum resolvedName = attr.name.length == 0 ? memberName : attr.name;
                        static if (resolvedName.indexOf(".") != -1)
                        {
                            static assert(
                                false,
                                "`@LuaExpose` names must not include dots. Use `@LuaApi` namespaces to model nested tables."
                            );
                        }
                        static if (attr.mode == LuaExposeMode.Function)
                        {
                            static if (!isCallable!memberSymbol)
                            {
                                static assert(
                                    false,
                                    "`@LuaExpose(..., mode: LuaExposeMode.Function)` requires a callable member."
                                );
                            }
                            else
                            {
                                LuaCallableDescriptor descriptor;
                                descriptor.symbolName = memberName;
                                descriptor.exportName = resolvedName;
                                descriptor.hostSignature = hostCallableSignature!memberSymbol(memberName);
                                descriptor.permission = attr.permission;
                                descriptor.mode = LuaExposeMode.Function;
                                descriptor.invoke = makeLuaInvoker!(T, memberName)(box);
                                collected.callables ~= descriptor;
                            }
                        }
                        else static if (attr.mode == LuaExposeMode.Value)
                        {
                            LuaValueDescriptor descriptor;
                            descriptor.symbolName = memberName;
                            descriptor.exportName = resolvedName;
                            descriptor.hostSignature = hostValueSignature!memberSymbol(memberName);
                            descriptor.permission = attr.permission;
                            descriptor.mode = LuaExposeMode.Value;
                            descriptor.valueMutability = attr.valueMutability;

                            static if (isCallable!memberSymbol)
                            {
                                enum inferredReadOnly = inferLuaValueReadOnly!(ReturnType!memberSymbol);
                                descriptor.readonlyValue = resolveLuaValueReadOnly(attr.valueMutability, inferredReadOnly);
                                descriptor.read = makeLuaValueGetterFromCallable!(T, memberName)(box);
                            }
                            else
                            {
                                mixin("alias FieldT = typeof(box.value." ~ memberName ~ ");");
                                enum inferredReadOnly = inferLuaValueReadOnly!FieldT;
                                descriptor.readonlyValue = resolveLuaValueReadOnly(attr.valueMutability, inferredReadOnly);
                                descriptor.read = makeLuaValueGetterFromField!(T, memberName)(box);
                            }
                            collected.values ~= descriptor;
                        }
                    }
                }
            }
        }
    }

    return collected;
}

private Result!(LuaValue, ScriptError) delegate(LuaValue[]) makeLuaInvoker(T, string memberName)(
    BindingBox!T box
)
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    alias ParamTypes = Parameters!memberSymbol;
    alias ReturnT = ReturnType!memberSymbol;

    return (LuaValue[] args) {
        if (args.length != ParamTypes.length)
        {
            return Result!(LuaValue, ScriptError).err(ScriptError(
                "Lua function `" ~ memberName ~ "` expected " ~ ParamTypes.length.to!string ~
                    " argument(s), but received " ~ args.length.to!string ~ ".",
                0
            ));
        }

        static if (ParamTypes.length == 0)
        {
            static if (is(ReturnT == void))
            {
                callVoid0!(T, memberName)(box);
                return Result!(LuaValue, ScriptError).ok(LuaValue.nil());
            }
            else
            {
                auto result = call0!(T, memberName)(box);
                return toLuaReturn!ReturnT(result, memberName);
            }
        }
        else static if (ParamTypes.length == 1)
        {
            auto arg0 = toHostArgument!(ParamTypes[0])(args[0], memberName, 1);
            if (arg0.isErr)
                return Result!(LuaValue, ScriptError).err(arg0.error);

            static if (is(ReturnT == void))
            {
                callVoid1!(T, memberName, ParamTypes[0])(box, arg0.value);
                return Result!(LuaValue, ScriptError).ok(LuaValue.nil());
            }
            else
            {
                auto result = call1!(T, memberName, ParamTypes[0])(box, arg0.value);
                return toLuaReturn!ReturnT(result, memberName);
            }
        }
        else static if (ParamTypes.length == 2)
        {
            auto arg0 = toHostArgument!(ParamTypes[0])(args[0], memberName, 1);
            if (arg0.isErr)
                return Result!(LuaValue, ScriptError).err(arg0.error);
            auto arg1 = toHostArgument!(ParamTypes[1])(args[1], memberName, 2);
            if (arg1.isErr)
                return Result!(LuaValue, ScriptError).err(arg1.error);

            static if (is(ReturnT == void))
            {
                callVoid2!(T, memberName, ParamTypes[0], ParamTypes[1])(box, arg0.value, arg1.value);
                return Result!(LuaValue, ScriptError).ok(LuaValue.nil());
            }
            else
            {
                auto result = call2!(T, memberName, ParamTypes[0], ParamTypes[1])(box, arg0.value, arg1.value);
                return toLuaReturn!ReturnT(result, memberName);
            }
        }
        else static if (ParamTypes.length == 3)
        {
            auto arg0 = toHostArgument!(ParamTypes[0])(args[0], memberName, 1);
            if (arg0.isErr)
                return Result!(LuaValue, ScriptError).err(arg0.error);
            auto arg1 = toHostArgument!(ParamTypes[1])(args[1], memberName, 2);
            if (arg1.isErr)
                return Result!(LuaValue, ScriptError).err(arg1.error);
            auto arg2 = toHostArgument!(ParamTypes[2])(args[2], memberName, 3);
            if (arg2.isErr)
                return Result!(LuaValue, ScriptError).err(arg2.error);

            static if (is(ReturnT == void))
            {
                callVoid3!(T, memberName, ParamTypes[0], ParamTypes[1], ParamTypes[2])(box, arg0.value, arg1.value, arg2.value);
                return Result!(LuaValue, ScriptError).ok(LuaValue.nil());
            }
            else
            {
                auto result = call3!(T, memberName, ParamTypes[0], ParamTypes[1], ParamTypes[2])(box, arg0.value, arg1.value, arg2.value);
                return toLuaReturn!ReturnT(result, memberName);
            }
        }
        else
        {
            return Result!(LuaValue, ScriptError).err(ScriptError(
                "Lua-exposed function `" ~ memberName ~ "` has too many parameters for the current Lua host bridge.",
                0
            ));
        }
    };
}

private Result!(LuaValue, ScriptError) delegate() makeLuaValueGetterFromCallable(T, string memberName)(
    BindingBox!T box
)
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    alias ParamTypes = Parameters!memberSymbol;
    alias ReturnT = ReturnType!memberSymbol;

    static assert(
        ParamTypes.length == 0,
        "`@LuaExpose(..., mode: LuaExposeMode.Value)` callable exports must not have parameters."
    );
    static assert(
        !is(ReturnT == void),
        "`@LuaExpose(..., mode: LuaExposeMode.Value)` callable exports must return a Lua-compatible value type."
    );

    return () {
        auto value = call0!(T, memberName)(box);
        return toLuaReturn!ReturnT(value, memberName);
    };
}

private Result!(LuaValue, ScriptError) delegate() makeLuaValueGetterFromField(T, string memberName)(
    BindingBox!T box
)
{
    mixin("alias FieldT = typeof(box.value." ~ memberName ~ ");");
    return () {
        auto value = mixin("box.value." ~ memberName);
        return toLuaReturn!FieldT(value, memberName);
    };
}

private void callVoid0(T, string memberName)(BindingBox!T box)
{
    mixin("box.value." ~ memberName ~ "();");
}

private auto call0(T, string memberName)(BindingBox!T box)
{
    return mixin("box.value." ~ memberName ~ "()");
}

private void callVoid1(T, string memberName, A0)(BindingBox!T box, A0 arg0)
{
    mixin("box.value." ~ memberName ~ "(arg0);");
}

private auto call1(T, string memberName, A0)(BindingBox!T box, A0 arg0)
{
    return mixin("box.value." ~ memberName ~ "(arg0)");
}

private void callVoid2(T, string memberName, A0, A1)(BindingBox!T box, A0 arg0, A1 arg1)
{
    mixin("box.value." ~ memberName ~ "(arg0, arg1);");
}

private auto call2(T, string memberName, A0, A1)(BindingBox!T box, A0 arg0, A1 arg1)
{
    return mixin("box.value." ~ memberName ~ "(arg0, arg1)");
}

private void callVoid3(T, string memberName, A0, A1, A2)(
    BindingBox!T box,
    A0 arg0,
    A1 arg1,
    A2 arg2
)
{
    mixin("box.value." ~ memberName ~ "(arg0, arg1, arg2);");
}

private auto call3(T, string memberName, A0, A1, A2)(
    BindingBox!T box,
    A0 arg0,
    A1 arg1,
    A2 arg2
)
{
    return mixin("box.value." ~ memberName ~ "(arg0, arg1, arg2)");
}

private Result!(LuaValue, ScriptError) toLuaReturn(T)(T value, string memberName)
{
    static if (is(T : string))
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(value.to!string));
    else static if (is(Unqual!T == bool))
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(cast(bool) value));
    else static if (isIntegral!T)
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(cast(long) value));
    else static if (isFloatingPoint!T)
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(cast(double) value));
    else static if (is(Unqual!T == LuaTable))
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(cast(LuaTable) value));
    else
        return Result!(LuaValue, ScriptError).err(ScriptError(
            "Lua-exposed function `" ~ memberName ~ "` returned unsupported type `" ~ T.stringof ~ "`.",
            0
        ));
}

private Result!(T, ScriptError) toHostArgument(T)(
    LuaValue value,
    string memberName,
    size_t argumentIndex
)
{
    static if (is(Unqual!T == LuaValue))
    {
        return Result!(T, ScriptError).ok(cast(T) value);
    }
    else static if (is(T == string))
    {
        if (value.kind == LuaValue.Kind.String)
            return Result!(T, ScriptError).ok(value.stringValue);
    }
    else static if (is(T == bool))
    {
        if (value.kind == LuaValue.Kind.Boolean)
            return Result!(T, ScriptError).ok(value.booleanValue);
    }
    else static if (is(T == int))
    {
        if (value.kind == LuaValue.Kind.Integer)
            return Result!(T, ScriptError).ok(cast(int) value.integerValue);
        if (value.kind == LuaValue.Kind.Number)
            return Result!(T, ScriptError).ok(cast(int) value.numberValue);
    }
    else static if (is(T == long))
    {
        if (value.kind == LuaValue.Kind.Integer)
            return Result!(T, ScriptError).ok(value.integerValue);
        if (value.kind == LuaValue.Kind.Number)
            return Result!(T, ScriptError).ok(cast(long) value.numberValue);
    }
    else static if (is(T == double))
    {
        if (value.kind == LuaValue.Kind.Number)
            return Result!(T, ScriptError).ok(value.numberValue);
        if (value.kind == LuaValue.Kind.Integer)
            return Result!(T, ScriptError).ok(cast(double) value.integerValue);
    }
    else static if (is(T == LuaTable))
    {
        if (value.kind == LuaValue.Kind.Table)
            return Result!(T, ScriptError).ok(value.tableValue);
    }

    return Result!(T, ScriptError).err(ScriptError(
        "Lua function `" ~ memberName ~ "` received incompatible type for argument " ~
            argumentIndex.to!string ~ ".",
        0
    ));
}

private extern (C) int invokeLuaCallable(lua_State* state) @trusted
{
    auto raw = lua_touserdata(state, luaUpvalueIndex(1));
    if (raw is null)
    {
        lua_pushlstring(state, "Lua callable lost its binding.".ptr, "Lua callable lost its binding.".length);
        return lua_error(state);
    }

    auto thunk = cast(LuaCallableThunk) raw;
    LuaValue[] args;

    foreach (index; 1 .. lua_gettop(state) + 1)
    {
        auto value = valueFromStack(state, index);
        if (value.isErr)
        {
            auto message = value.error.message;
            lua_pushlstring(state, message.ptr, message.length);
            return lua_error(state);
        }

        args ~= value.value;
    }

    auto result = thunk.invoke(args);
    if (result.isErr)
    {
        auto message = result.error.message;
        lua_pushlstring(state, message.ptr, message.length);
        return lua_error(state);
    }

    pushValue(state, result.value);
    return 1;
}

private Result!(LuaValue, ScriptError) valueFromStack(lua_State* state, int index) @trusted
{
    auto kind = lua_type(state, index);

    switch (kind)
    {
        case LuaTypeNil:
            return Result!(LuaValue, ScriptError).ok(LuaValue.nil());

        case LuaTypeBoolean:
            return Result!(LuaValue, ScriptError).ok(LuaValue.from(lua_toboolean(state, index) != 0));

        case LuaTypeNumber:
            if (lua_isinteger(state, index) != 0)
                return Result!(LuaValue, ScriptError).ok(LuaValue.from(cast(long) lua_tointegerx(state, index, null)));
            return Result!(LuaValue, ScriptError).ok(LuaValue.from(lua_tonumberx(state, index, null)));

        case LuaTypeString:
            return Result!(LuaValue, ScriptError).ok(LuaValue.from(stackString(state, index)));

        case LuaTypeTable:
            return Result!(LuaValue, ScriptError).ok(LuaValue.from(tableFromStack(state, index)));

        default:
            return Result!(LuaValue, ScriptError).err(ScriptError(
                "Lua value type `" ~ kind.to!string ~ "` is not supported by this Lua host bridge.",
                0
            ));
    }
}

private LuaTable tableFromStack(lua_State* state, int index) @trusted
{
    LuaTable table;
    auto absoluteIndex = lua_absindex(state, index);
    lua_pushnil(state);

    while (lua_next(state, absoluteIndex) != 0)
    {
        auto key = stackString(state, -2);
        auto value = valueFromStack(state, -1);
        if (value.isOk)
            table.values[key] = value.value.toDisplayString();
        luaPop(state, 1);
    }

    return table;
}

private void pushValue(lua_State* state, LuaValue value) @trusted
{
    final switch (value.kind)
    {
        case LuaValue.Kind.Nil:
            lua_pushnil(state);
            return;

        case LuaValue.Kind.String:
            lua_pushlstring(state, value.stringValue.ptr, value.stringValue.length);
            return;

        case LuaValue.Kind.Integer:
            lua_pushinteger(state, cast(lua_Integer) value.integerValue);
            return;

        case LuaValue.Kind.Number:
            lua_pushnumber(state, value.numberValue);
            return;

        case LuaValue.Kind.Boolean:
            lua_pushboolean(state, value.booleanValue ? 1 : 0);
            return;

        case LuaValue.Kind.Table:
            pushLuaTable(state, value.tableValue, false);
            return;
    }
}

private void pushExportedValue(lua_State* state, LuaValue value, bool readonlyTables) @trusted
{
    if (value.kind == LuaValue.Kind.Table)
    {
        pushLuaTable(state, value.tableValue, readonlyTables);
        return;
    }

    pushValue(state, value);
}

private void pushLuaTable(lua_State* state, LuaTable value, bool readonly) @trusted
{
    if (!readonly)
    {
        lua_createtable(state, 0, cast(int) value.values.length);
        foreach (key, item; value.values)
        {
            lua_pushlstring(state, item.ptr, item.length);
            lua_setfield(state, -2, toStringz(key));
        }
        return;
    }

    // Readonly export: return a proxy that delegates reads to a hidden source table and blocks writes.
    lua_createtable(state, 0, 0);
    auto proxyIndex = lua_absindex(state, -1);

    lua_createtable(state, 0, 3);
    lua_createtable(state, 0, cast(int) value.values.length);
    foreach (key, item; value.values)
    {
        lua_pushlstring(state, item.ptr, item.length);
        lua_setfield(state, -2, toStringz(key));
    }
    lua_setfield(state, -2, toStringz("__index"));

    lua_pushcclosure(state, &rejectReadOnlyTableMutation, 0);
    lua_setfield(state, -2, toStringz("__newindex"));
    lua_pushlstring(state, LuaReadOnlyValueError.ptr, LuaReadOnlyValueError.length);
    lua_setfield(state, -2, toStringz("__metatable"));
    lua_setmetatable(state, proxyIndex);
}

private extern (C) int rejectReadOnlyTableMutation(lua_State* state) @trusted
{
    lua_pushlstring(state, LuaReadOnlyValueError.ptr, LuaReadOnlyValueError.length);
    return lua_error(state);
}

private string stackString(lua_State* state, int index) @trusted
{
    size_t length;
    auto value = lua_tolstring(state, index, &length);
    if (value is null || length == 0)
        return "";
    return (cast(const(char)*) value)[0 .. length].idup;
}

private ScriptError scriptError(string message, string chunkName)
{
    return ScriptError(chunkName.length == 0 ? message : chunkName ~ ": " ~ message, extractLine(message));
}

private size_t extractLine(string message)
{
    foreach (index, ch; message)
    {
        if (ch != ':')
            continue;

        size_t end = index + 1;
        while (end < message.length && message[end] >= '0' && message[end] <= '9')
            end++;

        if (end > index + 1)
        {
            try
                return message[index + 1 .. end].to!size_t;
            catch (ConvException)
            {
                return 0;
            }
        }
    }

    return 0;
}

unittest
{
    auto split = splitLuaExportPath("botApi.double");
    assert(split.length == 2);
    assert(split[0] == "botApi");
    assert(split[1] == "double");
}

unittest
{
    struct SampleApi
    {
        @LuaExpose("double", LuaCapability.DiscordReply)
        long doubleValue(long value)
        {
            return value * 2;
        }
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!SampleApi(SampleApi.init);
    auto result = runtime.eval("return double(21)");

    assert(result.isOk);
    assert(result.value == "42");
}

unittest
{
    struct EmptyApi
    {
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!EmptyApi(EmptyApi.init);
    auto loaded = runtime.eval("function greet(name) return 'hello ' .. name end");

    assert(loaded.isOk);
    assert(runtime.hasCallable("greet"));

    auto called = runtime.call("greet", [LuaValue.from("world")]);
    assert(called.isOk);
    assert(called.value == "hello world");

    auto typed = runtime.callTyped("greet", [LuaValue.from("world")]);
    assert(typed.isOk);
    assert(typed.value.kind == LuaValue.Kind.String);
    assert(typed.value.stringValue == "hello world");
}

unittest
{
    struct SampleApi
    {
        @LuaExpose("author", LuaCapability.ContextRead)
        LuaTable author()
        {
            return LuaTable.safe("username", "alice");
        }
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!SampleApi(SampleApi.init, permissions: [LuaCapability.ContextRead]);
    auto result = runtime.eval("local user = author(); return user.username");

    assert(result.isOk);
    assert(result.value == "alice");
}

unittest
{
    struct SampleApi
    {
        @LuaExpose("ping", LuaCapability.DiscordReply)
        void ping()
        {
        }

        @LuaExpose("author", LuaCapability.ContextRead)
        void author()
        {
        }
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!SampleApi(SampleApi.init, permissions: [LuaCapability.ContextRead]);

    assert(runtime.exports.length == 1);
    assert(runtime.hasExport("author"));
    assert(!runtime.hasExport("ping"));
    assert(runtime.restrictedExports.length == 1);
    assert(runtime.restrictedExports[0].exportName == "ping");
}

unittest
{
    struct SampleApi
    {
        @LuaExpose("state_set", LuaCapability.StateWrite)
        void stateSet(string key, string value)
        {
            auto _ = key;
            auto __ = value;
        }
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!SampleApi(SampleApi.init, permissions: [LuaCapability.ContextRead]);
    auto result = runtime.eval("state_set('x', '1')");

    assert(result.isErr);
    assert(result.error.message.canFind("state.write"));
}

unittest
{
    @LuaApi(namespaceName: "state", exportGlobals: false)
    struct NamespacedRestrictedApi
    {
        @LuaExpose("set", LuaCapability.StateWrite)
        void setValue(string key, string value)
        {
            auto _ = key;
            auto __ = value;
        }
    }

    auto runtime = (new ScriptingEngine).open!NamespacedRestrictedApi(
        NamespacedRestrictedApi.init,
        permissions: [LuaCapability.ContextRead]
    );
    auto result = runtime.eval("state.set('x', '1')");

    assert(result.isErr);
    assert(result.error.message.canFind("state"));
}

unittest
{
    struct ValueApi
    {
        @LuaExpose("author", LuaCapability.ContextRead, LuaExposeMode.Value)
        LuaTable author()
        {
            return LuaTable.safe("username", "alice");
        }
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!ValueApi(ValueApi.init, permissions: [LuaCapability.ContextRead]);
    auto result = runtime.eval("return author.username");

    assert(result.isOk);
    assert(result.value == "alice");
    assert(runtime.hasExport("author"));
    assert(runtime.hasValue("author"));
    assert(!runtime.valueExportReadOnly("author"));
    assert(!runtime.hasCallable("author"));
}

unittest
{
    @LuaApi(namespaceName: "botApi", exportGlobals: false)
    struct NamespacedApi
    {
        @LuaExpose("double", LuaCapability.DiscordReply)
        long doubleValue(long value)
        {
            return value * 2;
        }

        @LuaExpose("author", LuaCapability.ContextRead, LuaExposeMode.Value)
        LuaTable author()
        {
            return LuaTable.safe("username", "eve");
        }
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!NamespacedApi(
        NamespacedApi.init,
        permissions: [LuaCapability.ContextRead, LuaCapability.DiscordReply]
    );
    assert(runtime.hasExport("botApi.double"), runtime.exportNames.join(","));
    assert(runtime.hasExport("botApi.author"), runtime.exportNames.join(","));
    auto tableExists = runtime.eval("return botApi ~= nil");
    assert(tableExists.isOk, tableExists.error.message);
    assert(tableExists.value == "true", tableExists.value);

    auto doubled = runtime.eval("return botApi.double(21)");
    assert(doubled.isOk, doubled.error.message);
    assert(doubled.value == "42");

    auto author = runtime.eval("return botApi.author.username");
    assert(author.isOk);
    assert(author.value == "eve");

    auto missing = runtime.eval("return double(21)");
    assert(missing.isErr);
}

unittest
{
    @LuaApi(namespaceName: "log", exportGlobals: false)
    struct LogNamespacedApi
    {
        @LuaExpose("info", LuaCapability.LogWrite)
        long info(long value)
        {
            return value + 1;
        }
    }

    @LuaApi(namespaceName: "macchi", exportGlobals: false)
    struct MacchiNamespacedApi
    {
        @LuaExpose("author", LuaCapability.ContextRead, LuaExposeMode.Value)
        LuaTable author()
        {
            return LuaTable.safe("username", "ada");
        }
    }

    auto runtime = (new ScriptingEngine).openMany!(LogNamespacedApi, MacchiNamespacedApi)(
        LogNamespacedApi.init,
        MacchiNamespacedApi.init,
        permissions: [LuaCapability.LogWrite, LuaCapability.ContextRead]
    );

    auto logged = runtime.eval("return log.info(41)");
    assert(logged.isOk);
    assert(logged.value == "42");

    auto author = runtime.eval("return macchi.author.username");
    assert(author.isOk);
    assert(author.value == "ada");
}

unittest
{
    @LuaApi(namespaceName: "log", exportGlobals: false)
    struct DynamicLogApi
    {
        @LuaExpose("info", LuaCapability.LogWrite)
        string info(LuaValue value)
        {
            return value.toDisplayString();
        }
    }

    auto runtime = (new ScriptingEngine).open!DynamicLogApi(
        DynamicLogApi.init,
        permissions: [LuaCapability.LogWrite]
    );

    auto fromString = runtime.eval("return log.info('hello')");
    assert(fromString.isOk);
    assert(fromString.value == "hello");

    auto fromNumber = runtime.eval("return log.info(41)");
    assert(fromNumber.isOk);
    assert(fromNumber.value == "41");

    auto fromNil = runtime.eval("return log.info(nil)");
    assert(fromNil.isOk);
    assert(fromNil.value == "nil");
}

unittest
{
    @LuaApi()
    struct YieldApi
    {
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!YieldApi(YieldApi.init);

    auto step = runtime.evalStepTyped(
        "local answer = coroutine.yield({ kind = 'ask_user', prompt = 'name?' }); return 'hello ' .. answer"
    );
    assert(step.isOk);
    assert(step.value.yielded);
    assert(runtime.canResume);

    string prompt;
    string kind;
    assert(LuaRuntime.yieldedSignalKind(step.value.value, kind));
    assert(kind == "ask_user");
    assert(LuaRuntime.yieldedTableField(step.value.value, "prompt", prompt));
    assert(prompt == "name?");

    auto resumed = runtime.resumeStepTyped(LuaValue.from("ada"));
    assert(resumed.isOk);
    assert(resumed.value.completed);
    assert(resumed.value.value.kind == LuaValue.Kind.String);
    assert(resumed.value.value.stringValue == "hello ada");
    assert(!runtime.canResume);
}

unittest
{
    @LuaApi()
    struct YieldApi
    {
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!YieldApi(YieldApi.init);

    auto yielded = runtime.evalTyped("local value = coroutine.yield('pause'); return value");
    assert(yielded.isErr);
    assert(runtime.canResume);

    auto resumed = runtime.resumeStep(LuaValue.from("resume-ok"));
    assert(resumed.isOk);
    assert(resumed.value == "resume-ok");
}

unittest
{
    @LuaApi()
    struct AutoResumeApi
    {
    }

    auto engine = new ScriptingEngine;
    auto runtime = engine.open!AutoResumeApi(AutoResumeApi.init);
    int askCalls;

    auto result = runtime.evalAutoResumeTyped(
        "local answer = coroutine.yield({ kind = 'ask_user', prompt = 'Which color?' }); return 'color=' .. answer",
        (LuaValue yielded) {
            askCalls++;
            string kind;
            string prompt;
            assert(LuaRuntime.yieldedSignalKind(yielded, kind));
            assert(kind == "ask_user");
            assert(LuaRuntime.yieldedTableField(yielded, "prompt", prompt));
            assert(prompt == "Which color?");
            return Result!(LuaValue, string).ok(LuaValue.from("blue"));
        }
    );

    assert(result.isOk);
    assert(result.value.kind == LuaValue.Kind.String);
    assert(result.value.stringValue == "color=blue");
    assert(askCalls == 1);
}

unittest
{
    struct ReadOnlyValueApi
    {
        @LuaExpose(
            "author",
            LuaCapability.ContextRead,
            LuaExposeMode.Value,
            LuaValueMutability.ReadOnly
        )
        LuaTable author()
        {
            return LuaTable.safe("username", "readonly");
        }
    }

    auto runtime = (new ScriptingEngine).open!ReadOnlyValueApi(ReadOnlyValueApi.init);
    auto changed = runtime.eval("author.username = 'mutated'; return author.username");

    assert(changed.isErr);
    assert(changed.error.message.canFind("readonly"));
    assert(runtime.valueExportReadOnly("author"));
}

unittest
{
    struct MutableValueApi
    {
        @LuaExpose(
            "author",
            LuaCapability.ContextRead,
            LuaExposeMode.Value,
            LuaValueMutability.Mutable
        )
        const(LuaTable) author()
        {
            auto table = LuaTable.safe("username", "const-backed");
            return table;
        }
    }

    auto runtime = (new ScriptingEngine).open!MutableValueApi(MutableValueApi.init);
    auto changed = runtime.eval("author.username = 'changed'; return author.username");

    assert(changed.isOk);
    assert(changed.value == "changed");
    assert(!runtime.valueExportReadOnly("author"));
}

unittest
{
    struct AutoReadOnlyConstTableApi
    {
        @LuaExpose("author", LuaCapability.ContextRead, LuaExposeMode.Value)
        const(LuaTable) author()
        {
            auto table = LuaTable.safe("username", "const-auto");
            return table;
        }
    }

    auto runtime = (new ScriptingEngine).open!AutoReadOnlyConstTableApi(AutoReadOnlyConstTableApi.init);
    auto changed = runtime.eval("author.username = 'changed'; return author.username");

    assert(changed.isErr);
    assert(changed.error.message.canFind("readonly"));
    assert(runtime.valueExportReadOnly("author"));
}

unittest
{
    struct ConstantValueApi
    {
        immutable string apiVersion = "1.2.3";

        @LuaExpose("version", LuaCapability.ContextRead, LuaExposeMode.Value)
        string versionValue()
        {
            return apiVersion;
        }
    }

    auto runtime = (new ScriptingEngine).open!ConstantValueApi(ConstantValueApi.init);
    auto resolvedVersion = runtime.eval("return version");

    assert(resolvedVersion.isOk);
    assert(resolvedVersion.value == "1.2.3");
}

unittest
{
    struct DuplicateExportsApi
    {
        @LuaExpose("dup", LuaCapability.ContextRead)
        void first()
        {
        }

        @LuaExpose("dup", LuaCapability.ContextRead, LuaExposeMode.Value)
        LuaTable second()
        {
            return LuaTable.safe("x", "1");
        }
    }

    bool threw;
    try
    {
        auto _ = (new ScriptingEngine).open!DuplicateExportsApi(DuplicateExportsApi.init);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("Duplicate Lua export names"));
    }

    assert(threw);
}

unittest
{
    auto capabilities = allLuaCapabilities();
    assert(capabilities.canFind(LuaCapability.ContextRead));
    assert(capabilities.canFind(LuaCapability.LogWrite));
}

unittest
{
    struct EmptyApi
    {
    }

    LuaRuntimeLimits limits;
    limits.maxExecutionTime = dur!"msecs"(50);
    limits.maxMemoryBytes = 4 * 1024 * 1024;
    limits.instructionCheckInterval = 2_000;

    auto runtime = (new ScriptingEngine).open!EmptyApi(
        EmptyApi.init,
        limits: limits
    );
    auto timedOut = runtime.eval("while true do end");

    assert(timedOut.isErr);
    assert(timedOut.error.message.canFind("time limit"));
}

unittest
{
    struct EmptyApi
    {
    }

    LuaRuntimeLimits limits;
    limits.maxExecutionTime = dur!"seconds"(2);
    limits.maxMemoryBytes = 64 * 1024;
    limits.instructionCheckInterval = 2_000;

    auto runtime = (new ScriptingEngine).open!EmptyApi(
        EmptyApi.init,
        limits: limits
    );
    auto memoryLimited = runtime.eval("local t={} for i=1,200000 do t[i]=string.rep('a', 16) end return #t");

    assert(memoryLimited.isErr);
    assert(memoryLimited.error.message.canFind("memory limit"));
}
