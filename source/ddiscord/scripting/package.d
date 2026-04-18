/**
 * ddiscord — scripting API surface.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.scripting;

import ddiscord.scripting.lua54;
import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.result : Result;
import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.string : toStringz;
import std.traits : Parameters, ReturnType, isCallable;

/// Capability flags for Lua host APIs.
enum LuaCapability
{
    ContextRead,
    DiscordReply,
    StateRead,
    StateWrite,
    Http,
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

    this(string name, LuaCapability permission = LuaCapability.ContextRead)
    {
        this.name = name;
        this.permission = permission;
    }
}

/// Error returned by script execution.
struct ScriptError
{
    string message;
    size_t line;
}

/// Metadata for a single exported Lua function.
struct LuaExportDescriptor
{
    string symbolName;
    string exportName;
    LuaCapability permission;
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
    LuaCapability permission;
    Result!(LuaValue, ScriptError) delegate(LuaValue[]) invoke;
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
    private LuaCallableThunk[] _thunks;

    this(LuaSandboxProfile profile, LuaCallableDescriptor[] callables)
    {
        _profile = profile;
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

        luaL_openlibs(_state);
        applySandbox();
        registerCallables(callables);
    }

    ~this()
    {
        if (_state !is null)
            lua_close(_state);
        _state = null;
    }

    Result!(LuaValue, ScriptError) evalValue(string code)
    {
        auto status = luaL_loadstring(_state, toStringz(code));
        return execute(status, "[eval]");
    }

    Result!(LuaValue, ScriptError) evalFileValue(string path)
    {
        auto status = luaL_loadfilex(_state, toStringz(path), null);
        return execute(status, path);
    }

    Result!(LuaValue, ScriptError) callValue(string globalName, LuaValue[] args = null)
    {
        lua_getglobal(_state, toStringz(globalName));

        auto globalType = lua_type(_state, -1);
        if (globalType == LuaTypeNil)
        {
            luaPop(_state, 1);
            return Result!(LuaValue, ScriptError).err(ScriptError(
                "Lua global `" ~ globalName ~ "` does not exist in this runtime.",
                0
            ));
        }

        if (globalType != LuaTypeFunction)
        {
            luaPop(_state, 1);
            return Result!(LuaValue, ScriptError).err(ScriptError(
                "Lua global `" ~ globalName ~ "` exists but is not callable.",
                0
            ));
        }

        foreach (arg; args)
            pushValue(_state, arg);

        auto status = luaPCall(_state, cast(int) args.length, 1, 0);
        if (status != LuaOk)
            return Result!(LuaValue, ScriptError).err(scriptError(lastErrorMessage(), globalName));

        auto result = valueFromStack(_state, -1);
        if (result.isErr)
        {
            luaPop(_state, 1);
            return result;
        }

        luaPop(_state, 1);
        return Result!(LuaValue, ScriptError).ok(result.value);
    }

    bool hasCallable(string globalName)
    {
        lua_getglobal(_state, toStringz(globalName));
        scope(exit) luaPop(_state, 1);
        return lua_type(_state, -1) == LuaTypeFunction;
    }

    private Result!(LuaValue, ScriptError) execute(int status, string chunkName)
    {
        if (status != LuaOk)
            return Result!(LuaValue, ScriptError).err(scriptError(lastErrorMessage(), chunkName));

        status = luaPCall(_state, 0, 1, 0);
        if (status != LuaOk)
            return Result!(LuaValue, ScriptError).err(scriptError(lastErrorMessage(), chunkName));

        scope(exit) luaPop(_state, 1);
        return valueFromStack(_state, -1);
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

    private void registerCallables(LuaCallableDescriptor[] callables)
    {
        foreach (callable; callables)
        {
            auto thunk = new LuaCallableThunk(callable.exportName, callable.invoke);
            _thunks ~= thunk;

            lua_pushlightuserdata(_state, cast(void*) thunk);
            lua_pushcclosure(_state, &invokeLuaCallable, 1);
            lua_setglobal(_state, toStringz(callable.exportName));
        }
    }

    private void removeGlobal(string name)
    {
        lua_pushnil(_state);
        lua_setglobal(_state, toStringz(name));
    }

    private string lastErrorMessage()
    {
        auto message = stackString(_state, -1);
        luaPop(_state, 1);
        return message;
    }
}

/// Execution-time runtime handle.
struct LuaRuntime
{
    LuaSandboxProfile profile;
    LuaCapability[] permissions;
    LuaExportDescriptor[] exports;
    private LuaVm _vm;

    /// Evaluates a Lua snippet.
    Result!(string, ScriptError) eval(string code)
    {
        if (code.length == 0)
            return Result!(string, ScriptError).err(ScriptError("empty script", 0));

        if (_vm is null)
            return Result!(string, ScriptError).err(ScriptError("runtime is not initialized", 0));

        auto result = _vm.evalValue(code);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.toDisplayString());
    }

    /// Evaluates a Lua file from disk.
    Result!(string, ScriptError) evalFile(string path)
    {
        if (path.length == 0)
            return Result!(string, ScriptError).err(ScriptError("empty path", 0));

        if (_vm is null)
            return Result!(string, ScriptError).err(ScriptError("runtime is not initialized", 0));

        auto result = _vm.evalFileValue(path);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.toDisplayString());
    }

    /// Calls an already-loaded global Lua function.
    Result!(string, ScriptError) call(string globalName, LuaValue[] args = null)
    {
        if (globalName.length == 0)
            return Result!(string, ScriptError).err(ScriptError("empty function name", 0));

        if (_vm is null)
            return Result!(string, ScriptError).err(ScriptError("runtime is not initialized", 0));

        auto result = _vm.callValue(globalName, args);
        if (result.isErr)
            return Result!(string, ScriptError).err(result.error);

        return Result!(string, ScriptError).ok(result.value.toDisplayString());
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
}

/// Minimal scripting engine surface.
final class ScriptingEngine
{
    /// Opens a runtime for a binding object.
    LuaRuntime open(T)(
        T binding,
        LuaSandboxProfile profile = LuaSandboxProfile.Untrusted,
        LuaCapability[] permissions = null
    )
    {
        auto box = new BindingBox!T(binding);
        auto callables = filterCallables(collectCallables!T(box), permissions);

        LuaRuntime runtime;
        runtime.profile = profile;
        runtime.permissions = permissions.dup;
        runtime.exports = toExportDescriptors(callables);
        runtime._vm = new LuaVm(profile, callables);
        return runtime;
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

private LuaExportDescriptor[] toExportDescriptors(LuaCallableDescriptor[] callables)
{
    LuaExportDescriptor[] exports;
    foreach (callable; callables)
    {
        LuaExportDescriptor descriptor;
        descriptor.symbolName = callable.symbolName;
        descriptor.exportName = callable.exportName;
        descriptor.permission = callable.permission;
        exports ~= descriptor;
    }
    return exports;
}

private LuaCallableDescriptor[] collectCallables(T)(BindingBox!T box)
{
    LuaCallableDescriptor[] exports;

    static foreach (memberName; __traits(allMembers, T))
    {
        {
            static if (memberName != "__ctor" && memberName != "__xdtor")
            {
                mixin("alias memberSymbol = T." ~ memberName ~ ";");
                static if (isCallable!memberSymbol)
                {
                    static foreach (attr; __traits(getAttributes, memberSymbol))
                    {
                        static if (is(typeof(attr) == LuaExpose))
                        {
                            LuaCallableDescriptor descriptor;
                            descriptor.symbolName = memberName;
                            descriptor.exportName = attr.name.length == 0 ? memberName : attr.name;
                            descriptor.permission = attr.permission;
                            descriptor.invoke = makeLuaInvoker!(T, memberName)(box);
                            exports ~= descriptor;
                        }
                    }
                }
            }
        }
    }

    return exports;
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
                "Lua-exposed function `" ~ memberName ~ "` has too many parameters for the current bridge.",
                0
            ));
        }
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
    static if (is(T == string))
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(value));
    else static if (is(T == bool))
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(value));
    else static if (is(T == int) || is(T == long))
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(cast(long) value));
    else static if (is(T == double) || is(T == float))
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(cast(double) value));
    else static if (is(T == LuaTable))
        return Result!(LuaValue, ScriptError).ok(LuaValue.from(value));
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
    static if (is(T == string))
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
                "Lua value type `" ~ kind.to!string ~ "` is not supported by the bridge.",
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
            lua_createtable(state, 0, cast(int) value.tableValue.values.length);
            foreach (key, item; value.tableValue.values)
            {
                lua_pushlstring(state, item.ptr, item.length);
                lua_setfield(state, -2, toStringz(key));
            }
            return;
    }
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
            catch (Exception)
            {
                return 0;
            }
        }
    }

    return 0;
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
}
