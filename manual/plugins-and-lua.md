# Plugins and Lua

`ddiscord` supports file-based Lua plugins and host APIs exposed from D.

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

## Exposing host APIs

```d
@LuaApi()
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

`@LuaApi()` creates a namespaced table (default `api`) with your exports only.
The runtime does not inject built-in Lua helper functions; use native Lua primitives
like `coroutine.yield(...)` directly when scripting yield/resume flows.

With `LuaExposeMode.Value`, scripts can read exports directly:

```lua
-- no parentheses:
return author.username
-- or namespaced:
return api.author.username
```

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

## Sandbox model

Untrusted runtimes do not get direct access to:

- `io`
- `os`
- `package`
- `debug`
- raw services
- host environment variables

What scripts do get is a narrow, explicit API built from `@LuaExpose` functions plus capability-gated plugin helpers like `state_get` and `state_set`.
