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
struct EvalLuaApi
{
    CommandContext ctx;

    @LuaExpose("send", LuaCapability.DiscordReply)
    void send(string content)
    {
        ctx.reply(content).await();
    }

    @LuaExpose("author", LuaCapability.ContextRead)
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

## Sandbox model

Untrusted runtimes do not get direct access to:

- `io`
- `os`
- `package`
- `debug`
- raw services
- host environment variables

What scripts do get is a narrow, explicit API built from `@LuaExpose` functions plus capability-gated plugin helpers like `state_get` and `state_set`.
