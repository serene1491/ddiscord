/**
 * ddiscord — minimal Lua 5.4 bindings.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.scripting.lua54;

pragma(lib, "lua5.4");

extern (C):

struct lua_State;

alias lua_Integer = long;
alias lua_Number = double;
alias lua_CFunction = int function(lua_State* L);
alias lua_KContext = long;
alias lua_KFunction = int function(lua_State* L, int status, lua_KContext ctx);

enum LuaOk = 0;
enum LuaMultRet = -1;

enum LuaTypeNil = 0;
enum LuaTypeBoolean = 1;
enum LuaTypeNumber = 3;
enum LuaTypeString = 4;
enum LuaTypeTable = 5;
enum LuaTypeFunction = 6;

enum LuaRegistryIndex = -1001000;

lua_State* luaL_newstate();
void luaL_openlibs(lua_State* L);
void lua_close(lua_State* L);

int luaL_loadstring(lua_State* L, const char* code);
int luaL_loadfilex(lua_State* L, const char* filename, const char* mode);
int lua_pcallk(lua_State* L, int nargs, int nresults, int errfunc, lua_KContext ctx, lua_KFunction k);
int lua_error(lua_State* L);

int lua_gettop(lua_State* L);
void lua_settop(lua_State* L, int idx);
int lua_absindex(lua_State* L, int idx);

int lua_type(lua_State* L, int idx);
int lua_isinteger(lua_State* L, int idx);
lua_Integer lua_tointegerx(lua_State* L, int idx, int* isnum);
lua_Number lua_tonumberx(lua_State* L, int idx, int* isnum);
int lua_toboolean(lua_State* L, int idx);
const(char)* lua_tolstring(lua_State* L, int idx, size_t* len);
void* lua_touserdata(lua_State* L, int idx);

void lua_pushnil(lua_State* L);
void lua_pushnumber(lua_State* L, lua_Number n);
void lua_pushinteger(lua_State* L, lua_Integer n);
const(char)* lua_pushlstring(lua_State* L, const(char)* s, size_t len);
void lua_pushboolean(lua_State* L, int b);
void lua_pushlightuserdata(lua_State* L, void* p);
void lua_pushcclosure(lua_State* L, lua_CFunction fn, int n);

int lua_getglobal(lua_State* L, const(char)* name);
void lua_setglobal(lua_State* L, const(char)* name);
int lua_getfield(lua_State* L, int idx, const(char)* k);
void lua_setfield(lua_State* L, int idx, const(char)* k);
void lua_createtable(lua_State* L, int narr, int nrec);
int lua_next(lua_State* L, int idx);

int luaPCall(lua_State* L, int nargs, int nresults, int errfunc)
{
    return lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}

void luaPop(lua_State* L, int count)
{
    lua_settop(L, -count - 1);
}

int luaUpvalueIndex(int index)
{
    return LuaRegistryIndex - index;
}
