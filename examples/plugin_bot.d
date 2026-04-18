module plugin_bot;

import ddiscord;
import std.conv : to;
import std.stdio : writeln;

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
        return LuaTable.safe(
            "id", ctx.user.id.toString,
            "username", ctx.user.username,
            "mention", ctx.user.mention
        );
    }
}

@LuaPlugin("counter", entrypoint: "counter.lua", sandbox: LuaSandboxProfile.Untrusted)
struct CounterPlugin
{
}

@Command("plugin-status", description: "Show the loaded Lua plugin state", routes: CommandRoute.Prefix)
void pluginStatus(CommandContext ctx)
{
    auto status = ctx.state.global.getOr!string("plugin:counter:status", "not loaded");
    auto loadCount = ctx.state.global.getOr!string("plugin:counter:load_count", "0");
    ctx.reply("counter plugin => status=" ~ status ~ ", loads=" ~ loadCount).await();
}

struct EvalCommands
{
    @Command("eval", description: "Evaluate a Lua snippet", routes: CommandRoute.Prefix)
    @RequireOwner
    void eval(CommandContext ctx, string code)
    {
        auto scripting = ctx.services.get!ScriptingEngine();
        auto runtime = scripting.open!EvalLuaApi(
            EvalLuaApi(ctx),
            LuaSandboxProfile.Untrusted,
            [LuaCapability.ContextRead, LuaCapability.DiscordReply]
        );

        auto result = runtime.eval(code);
        if (result.isOk)
            ctx.reply("lua => " ~ result.value).await();
        else
            ctx.reply("lua error => " ~ result.error.message).await();
    }
}

private Nullable!Snowflake optionalOwnerId(EnvLoader env)
{
    auto value = env.get!string("BOT_OWNER_ID", env.get!string("OWNER_ID", ""));
    if (value.length == 0)
        return Nullable!Snowflake.init;
    return Nullable!Snowflake.of(Snowflake(value.to!ulong));
}

void main()
{
    auto env = loadEnv("examples");

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
        prefix: env.get!string("BOT_PREFIX", "!"),
        pluginsDir: env.get!string("PLUGINS_DIR", "examples/plugins"),
        ownerId: optionalOwnerId(env)
    ));

    client.on!ReadyEvent((event) {
        writeln("[plugin] ready as ", event.selfUser.username);
    });

    client.registerCommands!pluginStatus();
    client.registerCommandGroup!EvalCommands();
    client.registerPlugin!CounterPlugin();
    client.setPresence(StatusType.Online, Activity(ActivityType.Listening, "Lua plugins"));
    client.run();
    writeln("[plugin] discovered plugins: ", client.plugins.registeredNames);
    client.wait();
}
