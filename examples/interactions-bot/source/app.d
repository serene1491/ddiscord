module app;

import ddiscord;
import std.path : buildPath;
import std.stdio : writeln;

private Modal feedbackModal()
{
    return Modal("interactions:feedback", "Quick Feedback")
        .addTextInput(
            TextInput("feedback_text", "What should improve?", TextInputStyle.Paragraph)
                .min(1)
                .max(200)
        );
}

private string submittedValue(InteractionSubmittedComponent[] components, string customId)
{
    foreach (component; components)
    {
        if (component.customId == customId)
            return component.value;
    }

    return "";
}

@Command("panel", description: "Send a feedback button panel", routes: CommandRoute.Slash)
void panel(CommandContext ctx)
{
    MessageCreate payload;
    payload = payload.withContent("Press the button to open a feedback modal.");
    payload = payload.addComponent(
        ActionRow().addComponent(Button("interactions:open_modal", "Open Feedback Modal", ButtonStyle.Primary))
    );
    ctx.send(payload).await();
}

@Command("feedback", description: "Open feedback modal directly", routes: CommandRoute.Slash)
void feedback(CommandContext ctx)
{
    ctx.showModal(feedbackModal()).await();
}

@Event
void onMessageComponent(MessageComponentEventContext ctx)
{
    if (ctx.customId != "interactions:open_modal")
        return;

    auto sent = ctx.rest.interactions.modal(
        ctx.interaction.id,
        ctx.interaction.token,
        feedbackModal()
    ).awaitResult();

    if (sent.isErr)
        ctx.logger.error("interactions", "modal open failed: " ~ sent.error);
}

@Event
void onModalSubmit(ModalSubmitEventContext ctx)
{
    if (ctx.interaction.customId != "interactions:feedback")
        return;

    auto text = submittedValue(ctx.submittedComponents, "feedback_text");
    auto preview = text.length == 0 ? "(empty)" : text;

    MessageCreate payload;
    payload = payload.withContent("Thanks for the feedback: `" ~ preview ~ "`");
    payload = payload.setFlag(MessageFlags.Ephemeral);

    auto sent = ctx.rest.interactions.send(ctx.interaction.id, ctx.interaction.token, payload).awaitResult();
    if (sent.isErr)
        ctx.logger.error("interactions", "modal submit response failed: " ~ sent.error);
}

@Event
void onReady(ReadyEventContext ctx)
{
    writeln("[interactions] ready as ", ctx.selfUser.username);
}

void main()
{
    auto env = loadEnv(buildPath(".."));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) GatewayIntent.Guilds,
        prefix: env.get!string("BOT_PREFIX", "!")
    ));

    client.registerAllCommands();
    client.setPresence(StatusType.Online, Activity(ActivityType.Playing, "components + modals"));

    client.run();
    writeln("[interactions] synced commands: ", client.commands.applicationCommands.length);
    client.wait();
}
