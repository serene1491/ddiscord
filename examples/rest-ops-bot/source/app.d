module app;

import ddiscord;
import std.conv : to;
import std.datetime : dur;
import std.path : buildPath;
import std.stdio : writeln;

@Event
void onReady(ReadyEventContext ctx)
{
    writeln("[rest-ops] ready as ", ctx.selfUser.username);
}

@Command("guild-check", description: "Demo for named middleware via @UseMiddleware", routes: CommandRoute.Prefix)
@UseMiddleware("guild_only")
void guildMiddlewareProbe(CommandContext ctx)
{
    ctx.send("Guild middleware check passed.").await();
}

@Command("react", description: "React to the invoking message", routes: CommandRoute.Prefix)
void reactToMessage(CommandContext ctx, string emoji = "✅")
{
    auto added = ctx.react(emoji).awaitResult();
    if (added.isErr)
    {
        ctx.send("Failed to add reaction: " ~ added.error).await();
        return;
    }

    ctx.send("Reaction added: " ~ emoji).await();
}

@Command("unreact", description: "Remove the bot reaction from the invoking message", routes: CommandRoute.Prefix)
void unreactToMessage(CommandContext ctx, string emoji = "✅")
{
    auto removed = ctx.unreact(emoji).awaitResult();
    if (removed.isErr)
    {
        ctx.send("Failed to remove reaction: " ~ removed.error).await();
        return;
    }

    ctx.send("Reaction removed: " ~ emoji).await();
}

@Command("purge2", description: "Bulk-delete exactly two messages by id", routes: CommandRoute.Prefix)
void purgeTwo(CommandContext ctx, ulong firstMessageId, ulong secondMessageId)
{
    Snowflake[] ids = [Snowflake(firstMessageId), Snowflake(secondMessageId)];
    auto deleted = ctx.rest.messages.bulkDelete(ctx.channel.id, ids).awaitResult();
    if (deleted.isErr)
    {
        ctx.send("Bulk delete failed: " ~ deleted.error).await();
        return;
    }

    ctx.send("Bulk delete completed for 2 messages.").await();
}

@Command("crosspost", description: "Crosspost a message in announcement channels", routes: CommandRoute.Prefix)
void crosspostMessage(CommandContext ctx, ulong messageId = 0)
{
    auto reference = ctx.messageRef;
    if (messageId != 0)
    {
        if (ctx.channel.id.value == 0)
        {
            ctx.send("Provide channel context when passing manual message id.").await();
            return;
        }

        CommandMessageRef custom;
        custom.rest = ctx.rest;
        custom.channelId = ctx.channel.id;
        custom.messageId = Snowflake(messageId);
        reference = Nullable!CommandMessageRef.of(custom);
    }

    if (reference.isNull)
    {
        ctx.send("Provide a message id or run this from a message context.").await();
        return;
    }

    auto crossposted = reference.get.crosspost().awaitResult();
    if (crossposted.isErr)
    {
        ctx.send("Crosspost failed: " ~ crossposted.error).await();
        return;
    }

    ctx.send("Crossposted message: " ~ crossposted.value.id.toString).await();
}

@Command("pin", description: "Pin a message in this channel", routes: CommandRoute.Prefix)
void pinMessage(CommandContext ctx, ulong messageId = 0, string reason = "Pinned from rest-ops-bot")
{
    Snowflake targetMessageId = Snowflake(messageId);
    auto pinned = targetMessageId.value == 0
        ? ctx.pin(Nullable!string.of(reason)).awaitResult()
        : ctx.rest.messages.pin(ctx.channel.id, targetMessageId, Nullable!string.of(reason)).awaitResult();
    if (pinned.isErr)
    {
        ctx.send("Pin failed: " ~ pinned.error).await();
        return;
    }

    auto summary = targetMessageId.value == 0 && !ctx.message.isNull
        ? ctx.message.get.id.toString
        : targetMessageId.toString;
    ctx.send("Pinned message: " ~ summary).await();
}

@Command("unpin", description: "Unpin a message in this channel", routes: CommandRoute.Prefix)
void unpinMessage(CommandContext ctx, ulong messageId, string reason = "Unpinned from rest-ops-bot")
{
    auto unpinned = ctx.rest.messages.unpin(
        ctx.channel.id,
        Snowflake(messageId),
        Nullable!string.of(reason)
    ).awaitResult();
    if (unpinned.isErr)
    {
        ctx.send("Unpin failed: " ~ unpinned.error).await();
        return;
    }

    ctx.send("Unpinned message: " ~ messageId.to!string).await();
}

@Command("pins", description: "List pinned messages in this channel", routes: CommandRoute.Prefix)
void listPins(CommandContext ctx)
{
    auto pins = ctx.rest.messages.pins(ctx.channel.id).awaitResult();
    if (pins.isErr)
    {
        ctx.send("Pinned list failed: " ~ pins.error).await();
        return;
    }

    if (pins.value.length == 0)
    {
        ctx.send("No pinned messages in this channel.").await();
        return;
    }

    auto first = pins.value[0];
    ctx.send(
        "Pinned messages: " ~ pins.value.length.to!string ~
        " (latest sample id: " ~ first.id.toString ~ ")"
    ).await();
}

@Command("timeout", description: "Timeout a member in the current guild", routes: CommandRoute.Prefix)
void timeoutMember(
    CommandContext ctx,
    ulong userId,
    long minutes = 5,
    string reason = "Timed out from rest-ops-bot"
)
{
    if (ctx.guild.isNull)
    {
        ctx.send("This command only works in guild channels.").await();
        return;
    }

    if (minutes <= 0)
    {
        ctx.send("Minutes must be > 0.").await();
        return;
    }

    auto timed = ctx.rest.guilds.timeoutMember(
        ctx.guild.get.id,
        Snowflake(userId),
        dur!"minutes"(minutes),
        Nullable!string.of(reason)
    ).awaitResult();
    if (timed.isErr)
    {
        ctx.send("Timeout failed: " ~ timed.error).await();
        return;
    }

    ctx.send("Member timed out.").await();
}

@Command("untimeout", description: "Clear member timeout in the current guild", routes: CommandRoute.Prefix)
void clearMemberTimeout(
    CommandContext ctx,
    ulong userId,
    string reason = "Timeout cleared from rest-ops-bot"
)
{
    if (ctx.guild.isNull)
    {
        ctx.send("This command only works in guild channels.").await();
        return;
    }

    auto cleared = ctx.rest.guilds.clearMemberTimeout(
        ctx.guild.get.id,
        Snowflake(userId),
        Nullable!string.of(reason)
    ).awaitResult();
    if (cleared.isErr)
    {
        ctx.send("Timeout clear failed: " ~ cleared.error).await();
        return;
    }

    ctx.send("Member timeout cleared.").await();
}

@Command("thread", description: "Create a thread from the invoking message", routes: CommandRoute.Prefix)
void createThreadFromCurrentMessage(CommandContext ctx, string name = "ops-thread")
{
    if (ctx.message.isNull)
    {
        ctx.send("This command requires a message context.").await();
        return;
    }

    auto created = ctx.rest.threads.createFromMessage(
        ctx.channel.id,
        ctx.message.get.id,
        name
    ).awaitResult();
    if (created.isErr)
    {
        ctx.send("Thread create failed: " ~ created.error).await();
        return;
    }

    ctx.send("Thread created: " ~ created.value.name).await();
}

@Command("thread-join", description: "Join a thread by id", routes: CommandRoute.Prefix)
void joinThread(CommandContext ctx, ulong threadId)
{
    auto joined = ctx.rest.threads.join(Snowflake(threadId)).awaitResult();
    if (joined.isErr)
    {
        ctx.send("Thread join failed: " ~ joined.error).await();
        return;
    }

    ctx.send("Joined thread.").await();
}

@Command("thread-leave", description: "Leave a thread by id", routes: CommandRoute.Prefix)
void leaveThread(CommandContext ctx, ulong threadId)
{
    auto left = ctx.rest.threads.leave(Snowflake(threadId)).awaitResult();
    if (left.isErr)
    {
        ctx.send("Thread leave failed: " ~ left.error).await();
        return;
    }

    ctx.send("Left thread.").await();
}

@Command("thread-archive", description: "Archive a thread by id", routes: CommandRoute.Prefix)
void archiveThread(CommandContext ctx, ulong threadId)
{
    auto archived = ctx.rest.threads.archive(Snowflake(threadId), true, false).awaitResult();
    if (archived.isErr)
    {
        ctx.send("Thread archive failed: " ~ archived.error).await();
        return;
    }

    ctx.send("Thread archived: " ~ archived.value.name).await();
}

@Command("webhook-send", description: "Execute a webhook message", routes: CommandRoute.Prefix)
void sendWebhookMessage(
    CommandContext ctx,
    ulong webhookId,
    string token,
    string content = "hello from rest-ops-bot"
)
{
    auto sent = ctx.rest.webhooks.execute(
        Snowflake(webhookId),
        token,
        MessageCreate(content)
    ).awaitResult();
    if (sent.isErr)
    {
        ctx.send("Webhook execute failed: " ~ sent.error).await();
        return;
    }

    ctx.send("Webhook sent message id: " ~ sent.value.id.toString).await();
}

void main()
{
    auto env = loadEnv(buildPath(".."));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) GatewayIntent.GuildTextCommandsWithReactions,
        prefix: env.get!string("BOT_PREFIX", "!")
    ));

    client.registerAllCommands();
    client.setPresence(StatusType.Online, Activity(ActivityType.Listening, "REST ops"));

    client.run();
    client.wait();
}
