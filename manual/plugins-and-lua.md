# Plugins and Lua

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

`ddiscord` supports file-based Lua plugins and host APIs exposed from D.

## Mental model

Think in layers:

1. D host defines safe capabilities and APIs
2. Lua runtime exposes only what is allowed
3. Scripts/plugins consume that API surface
4. Host controls lifecycle, logging, persistence, and recovery

## Plugin layout

```text
plugins/
└── counter/
    ├── plugin.json
    └── main.lua
```

Example manifest:

```json
{
  "name": "counter",
  "version": "1.0.0",
  "ddiscordApiVersion": "2",
  "scripts": ["main.lua"],
  "permissions": ["state.read", "state.write"],
  "sandbox": "untrusted"
}
```

## Loading plugins

Set `pluginsDir` in `ClientConfig`:

```d
auto client = new Client(ClientConfig(
    token: env.require!string("TOKEN"),
    intents: cast(uint) GatewayIntent.Guilds,
    pluginsDir: "plugins"
));
```

During `run()`, the client:

1. scans the directory
2. validates plugin manifests
3. creates a sandboxed Lua runtime
4. loads the Lua file
5. runs `onLoad()` and `onEnable()` when present

Operational tip:

1. Keep plugin startup light.
2. Move expensive work to explicit commands or scheduled tasks.
3. Log plugin load boundaries with clear names.

## Exposing host APIs

```d
@LuaApi(namespaceName: "context", exportGlobals: false)
struct EvalLuaApi
{
    CommandContext ctx;

    @LuaExpose("send", LuaCapability.DiscordReply)
    void send(string content)
    {
        ctx.reply(content).await();
    }

    @LuaExpose(
        "author",
        LuaCapability.ContextRead,
        LuaExposeMode.Value,
        LuaValueMutability.ReadOnly
    )
    LuaTable author()
    {
        return LuaTable.safe("username", ctx.user.username);
    }
}
```

Then open a runtime:

```d
auto runtime = client.openLuaRuntime(
    EvalLuaApi(ctx),
    LuaSandboxProfile.Untrusted,
    [LuaCapability.ContextRead, LuaCapability.DiscordReply]
);
```

`@LuaApi` creates a namespaced table. Use `namespaceName` + `exportGlobals: false`
to force a clean table-only surface (recommended for large bots).
The runtime does not inject built-in Lua helper functions; use native Lua primitives
like `coroutine.yield(...)` directly when scripting yield/resume flows.

Important:

- `@LuaExpose("name")` must be a single symbol name (no dots).
- Nesting is modeled by combining APIs (multiple `@LuaApi` bindings), not by dotted export names.
- You can merge bindings with `ScriptingEngine.openMany(...)` and keep each API in its own namespace.

Example:

```d
auto runtime = (new ScriptingEngine).openMany!(CommandApi, LoggingApi)(
    CommandApi(ctx),       // @LuaApi("command", exportGlobals: false)
    LoggingApi(ctx),       // @LuaApi("log", exportGlobals: false)
    profile: LuaSandboxProfile.Untrusted,
    permissions: [LuaCapability.ContextRead, LuaCapability.LogWrite]
);
```

With `LuaExposeMode.Value`, scripts can read exports directly:

```lua
-- no parentheses:
return author.username
-- or namespaced:
return api.author.username
```

Design guideline:

1. Use `ctx` namespace for read-only execution context values.
2. Use `macchi` or equivalent namespace for active operations (`reply`, `send`, mutations).
3. Keep domain logic in Lua script files, not hardcoded in D host APIs.

Value mutability is configurable:

- `LuaValueMutability.Auto` (default): inferred from D type qualifiers for `LuaTable` exports.
  - `LuaTable` -> mutable in Lua
  - `const(LuaTable)` / `immutable(LuaTable)` -> readonly in Lua
- `LuaValueMutability.Mutable`: always mutable in Lua
- `LuaValueMutability.ReadOnly`: always readonly in Lua

You can also configure `@LuaApi`:

```d
@LuaApi(namespaceName: "api", exportGlobals: false)
struct MyLuaApi
{
    // ...
}
```

## Runtime inspection (debugging)

`LuaRuntime` exposes metadata for debugging and docs generation:

- `exports` (`LuaExportDescriptor[]`): effective Lua names currently visible
- `restrictedExports`: names hidden by missing capabilities
- `exportNames`, `callableExportNames`, `valueExportNames`
- per-export metadata: `mode`, `permission`, `hostSignature`

This is useful for building `/lua-apis` style commands inside your bot.

## Yield / Resume

`LuaRuntime` supports coroutine stepping:

```d
auto step = runtime.evalStepTyped(
    "local answer = coroutine.yield({ kind = 'ask_user', prompt = 'Name?' }); return 'hi ' .. answer"
);
if (step.isOk && step.value.yielded)
{
    auto resumed = runtime.resumeStepTyped(LuaValue.from("Ada"));
    // resumed.value.completed == true
}
```

Helpers:

- `evalStepTyped`, `evalFileStepTyped`, `callStepTyped`
- `resumeStepTyped` (`LuaValue[]` or single `LuaValue`), `canResume`, `cancelSuspension`
- `evalAutoResumeTyped` / `callAutoResumeTyped` (host callback handles yielded payloads)
- `yieldedSignalKind` / `yieldedTableField` (inspect yielded table payloads safely)

About callbacks and yield:

1. `yield` exists to suspend Lua and let the host decide when/how to resume.
2. You can model host coordination with an `onYield` callback concept.
3. Avoid hardcoded payload schemas in the runtime core unless your product requires a fixed contract.

## Sandbox model

Untrusted runtimes do not get direct access to:

- `io`
- `os`
- `package`
- `debug`
- raw services
- host environment variables

What scripts do get is a narrow, explicit API built from `@LuaExpose` functions plus capability-gated plugin helpers like `state_get` and `state_set`.

## Debug and safety checklist

Before shipping plugin/Lua features:

1. List runtime exports in a debug command (`runtime.exports`)
2. Confirm restricted exports for missing permissions (`runtime.restrictedExports`)
3. Validate user-provided Lua source before saving
4. Ensure replies/messages happen during execution flow (not by synthetic completion strings)
5. Keep logs focused on useful lifecycle and failure events

Related guides:

- [Commands Guide](commands.md)
- [State and Tasks](state-and-tasks.md)
- [Troubleshooting](troubleshooting.md)
