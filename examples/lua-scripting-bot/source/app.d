module app;

import ddiscord;
import ddiscord.client_text : PrefixInvocation, parsePrefixInvocation, tokenizePrefixContent;
import ddiscord.services : ServiceContainer;
import models : SavedScript;
import ddiscord.util.result : Result;
import std.algorithm.iteration : map;
import std.array : join;
import std.exception : enforce;
import std.file : exists;
import std.path : buildPath;
import std.process : spawnProcess, wait;
import std.stdio : writeln;
import std.string : startsWith, strip;
import std.ascii : toLower;
import store : ScriptStore;

enum DatabasePath = "scripts.sqlite3";
enum PreviewLength = 1_200;

final class LuaScriptApi
{
    CommandContext ctx;
    SavedScript script;
    string rawArgs;
    bool replied;

    this(CommandContext ctx, SavedScript script, string rawArgs)
    {
        this.ctx = ctx;
        this.script = script;
        this.rawArgs = rawArgs;
    }

    @LuaExpose("reply", LuaCapability.DiscordReply)
    void reply(LuaValue content)
    {
        ctx.reply(content.toDisplayString()).await();
        replied = true;
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

    @LuaExpose("args", LuaCapability.ContextRead)
    string args()
    {
        return rawArgs;
    }

    @LuaExpose("arg", LuaCapability.ContextRead)
    string arg(long index)
    {
        auto argv = tokenizePrefixContent(rawArgs);
        auto resolved = cast(ptrdiff_t) index - 1;
        if (resolved < 0 || resolved >= argv.length)
            return "";
        return argv[resolved];
    }

    @LuaExpose("script_name", LuaCapability.ContextRead)
    string scriptName()
    {
        return script.name;
    }

    @LuaExpose("scope", LuaCapability.ContextRead)
    string scriptScope()
    {
        return script.scopeType;
    }

    @LuaExpose("log", LuaCapability.LogWrite)
    void logMessage(LuaValue message)
    {
        ctx.services.get!Logger().information("lua-script", "[" ~ script.name ~ "] " ~ message.toDisplayString());
    }
}

@Command("save-script", description: "Save a new Lua script", routes: CommandRoute.Slash)
void saveScript(
    CommandContext ctx,
    @Option("name", "Saved command name") string name,
    @Option("scope", "user or server") string scopeValue = "user",
    @Option("source", "Lua source code") string source = ""
)
{
    auto store = requireScriptStore(ctx.services);
    auto reserved = validateReservedName(name);
    if (!reserved.isNull)
    {
        ctx.send(reserved.get, ephemeral: true).await();
        return;
    }

    auto created = store.create(scopeValue, name, source, ctx.user.id, ctx.messageGuildId);
    if (created.isErr)
        ctx.send(created.error, ephemeral: true).await();
    else
        ctx.send("Saved `" ~ created.value.name ~ "` as a " ~ created.value.scopeType ~ " script.", ephemeral: true)
                .await();
}

@Command("show-script", description: "Show a saved Lua script", routes: CommandRoute.Slash)
void showScript(
    CommandContext ctx,
    @Option("name", "Saved command name") string name,
    @Option("scope", "user or server") string scopeValue = "user"
)
{
    auto shown = requireScriptStore(ctx.services).show(scopeValue, name, ctx.user.id, ctx.messageGuildId);
    if (shown.isErr)
    {
        ctx.send(shown.error, ephemeral: true).await();
        return;
    }

    ctx.send(formatScriptPreview(shown.value), ephemeral: true).await();
}

@Command("update-script", description: "Update an owned Lua script", routes: CommandRoute.Slash)
void updateScript(
    CommandContext ctx,
    @Option("name", "Saved command name") string name,
    @Option("scope", "user or server") string scopeValue = "user",
    @Option("source", "Replacement Lua source code") string source = ""
)
{
    auto updated = requireScriptStore(ctx.services).update(scopeValue, name, source, ctx.user.id, ctx.messageGuildId);
    if (updated.isErr)
        ctx.send(updated.error, ephemeral: true).await();
    else
        ctx.send("Updated `" ~ updated.value.name ~ "`.", ephemeral: true).await();
}

@Command("delete-script", description: "Delete an owned Lua script", routes: CommandRoute.Slash)
void deleteScript(
    CommandContext ctx,
    @Option("name", "Saved command name") string name,
    @Option("scope", "user or server") string scopeValue = "user"
)
{
    auto removed = requireScriptStore(ctx.services).remove(scopeValue, name, ctx.user.id, ctx.messageGuildId);
    if (removed.isErr)
        ctx.send(removed.error, ephemeral: true).await();
    else
        ctx.send("Deleted `" ~ name.strip ~ "`.", ephemeral: true).await();
}

@Command("list-scripts", description: "List scripts you can run", routes: CommandRoute.Slash)
void listScripts(CommandContext ctx)
{
    auto listed = requireScriptStore(ctx.services).listAvailable(ctx.user.id, ctx.messageGuildId);
    if (listed.isErr)
    {
        ctx.send(listed.error, ephemeral: true).await();
        return;
    }

    if (listed.value.length == 0)
    {
        ctx.send("No scripts are available yet.", ephemeral: true).await();
        return;
    }

    string[] lines;
    foreach (script; listed.value)
        lines ~= "`" ~ script.name ~ "` (" ~ script.scopeType ~ ")";

    ctx.send("Available scripts:\n" ~ lines.join("\n"), ephemeral: true).await();
}

@HybridCommand("run", "Run a saved Lua script")
void runScript(
    HybridContext ctx,
    @Option("name", "Saved command name") string name = "",
    @Greedy @Option("args", "Arguments passed to the script") string args = ""
)
{
    auto store = requireScriptStore(ctx.services);
    auto requestedName = name.strip;
    if (requestedName.length == 0)
    {
        auto listed = store.listAvailable(ctx.user.id, ctx.messageGuildId);
        if (listed.isErr)
            ctx.send(listed.error, ctx.source == CommandSource.Slash).await();
        else if (listed.value.length == 0)
            ctx.send("No scripts are available yet.", ctx.source == CommandSource.Slash).await();
        else
            ctx.send("Try one of: " ~ listed.value.map!(script => "`" ~ script.name ~ "`")
                                                   .join(", "), ctx.source == CommandSource.Slash).await();
        return;
    }

    auto script = store.findRunnable(requestedName, ctx.user.id, ctx.messageGuildId);
    if (script.isErr)
    {
        ctx.send(script.error, ctx.source == CommandSource.Slash).await();
        return;
    }

    auto executed = executeScript(ctx, script.value, args.strip);
    if (executed.isErr)
        ctx.send(executed.error, ctx.source == CommandSource.Slash).await();
}

void main()
{
    auto env = loadEnv(buildPath(".."));
    ensureDatabaseReady();

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) GatewayIntent.GuildTextCommands,
        prefix: env.get!string("BOT_PREFIX", "!"),
        autoSyncCommands: true
    ));

    client.services.add!ScriptStore(new ScriptStore(DatabasePath));

    client.on!ReadyEvent((event) {
        writeln("[lua] ready as ", event.selfUser.username);
    });

    client.on!MessageCreateEvent((event) {
        runSavedPrefixScript(client, event);
    });

    client.registerCommands();
    client.setPresence(StatusType.Online, Activity(ActivityType.Playing, "Your scripts"));
    client.run();
    client.wait();
}

private void runSavedPrefixScript(Client client, MessageCreateEvent event)
{
    if (event.message.author.bot || !event.message.content.startsWith(client.config.prefix))
        return;

    auto invocation = parsePrefixedName(client.config.prefix, event.message.content);
    if (invocation.name.length == 0)
        return;

    if (!client.commands.find(invocation.name, CommandRoute.Prefix).isNull)
        return;

    auto store = requireScriptStore(client.services);
    auto script = store.findRunnable(invocation.name, event.message.author.id, event.message.guildId);
    if (script.isErr)
        return;

    Channel channel;
    channel.id = event.message.channelId;

    auto ctx = client.prefixContext(event.message.content, event.message.author, channel);
    ctx.message = Nullable!Message.of(event.message);

    auto executed = executeScript(ctx, script.value, invocation.args.strip);
    if (executed.isErr)
        ctx.send(executed.error).await();
}

private Result!(bool, string) executeScript(CommandContext ctx, SavedScript script, string rawArgs)
{
    auto scripting = ctx.services.get!ScriptingEngine();
    auto api = new LuaScriptApi(ctx, script, rawArgs);
    auto runtime = scripting.open!LuaScriptApi(
        api,
        LuaSandboxProfile.Untrusted,
        [LuaCapability.ContextRead, LuaCapability.DiscordReply, LuaCapability.LogWrite]
    );

    auto result = runtime.eval(script.source);
    if (result.isErr)
        return Result!(bool, string).err("Lua error in `" ~ script.name ~ "`: " ~ result.error.message);

    auto output = result.value.strip;
    if (!api.replied && shouldSendScriptOutput(output))
        ctx.send(output).await();

    return Result!(bool, string).ok(true);
}

private bool shouldSendScriptOutput(string output)
{
    auto normalized = output.strip;
    return normalized.length != 0 && normalized != "nil";
}

private Nullable!string validateReservedName(string rawName)
{
    auto name = asciiLower(rawName.strip);
    foreach (reserved; ["run", "save-script", "show-script", "update-script", "delete-script", "list-scripts"])
    {
        if (name == reserved)
        {
            return Nullable!string.of(
                "The name `" ~ name ~ "` is reserved by the example bot. Pick another saved command name."
            );
        }
    }

    return Nullable!string.init;
}

private Nullable!Snowflake messageGuildId(CommandContext ctx) @property
{
    if (!ctx.message.isNull)
        return ctx.message.get.guildId;
    if (!ctx.interaction.isNull)
        return ctx.interaction.get.guildId;
    return Nullable!Snowflake.init;
}

private string formatScriptPreview(SavedScript script)
{
    auto source = script.source;
    if (source.length > PreviewLength)
        source = source[0 .. PreviewLength] ~ "\n-- truncated --";

    return "Script `" ~ script.name ~ "` (" ~ script.scopeType ~ ")\n```lua\n" ~ source ~ "\n```";
}

private void ensureDatabaseReady()
{
    if (exists(DatabasePath))
        return;

    writeln("[lua] initializing SQLite schema with Dorm migrations");
    auto migrate = spawnProcess(["dub", "run", "dorm", "--", "migrate"]);
    if (wait(migrate) != 0)
        throw new Exception("Could not initialize the Dorm SQLite schema.");
}

private PrefixInvocation parsePrefixedName(string prefix, string content)
{
    return parsePrefixInvocation(prefix, content);
}

private ScriptStore requireScriptStore(ServiceContainer services)
{
    ScriptStore store;
    enforce(services.tryGet!ScriptStore(store), "The example ScriptStore service is not registered.");
    return store;
}

private string asciiLower(string input)
{
    auto lowered = input.dup;
    foreach (index, ch; lowered)
        lowered[index] = toLower(ch);
    return lowered.idup;
}
