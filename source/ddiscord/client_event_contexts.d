/**
 * ddiscord — client event-context builders.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_event_contexts;

import ddiscord.context.command : CommandContext;
import ddiscord.context.event : AutocompleteInteractionEventContext, ChannelCreateEventContext,
    BotMentionEventContext, ButtonComponentEventContext, ChannelDeleteEventContext,
    ChannelPinsUpdateEventContext, ChannelSelectComponentEventContext, ChannelUpdateEventContext,
    CommandExecutedEventContext, CommandFailedEventContext, EventContext, GuildCreateEventContext,
    GatewayDispatchEventContext, GuildDeleteEventContext, GuildMemberAddEventContext, GuildMemberRemoveEventContext,
    GuildUpdateEventContext,
    GuildBanAddEventContext, GuildBanRemoveEventContext, GuildRoleCreateEventContext,
    GuildRoleDeleteEventContext, GuildRoleUpdateEventContext, InteractionCreateEventContext,
    InviteCreateEventContext, InviteDeleteEventContext, MentionableSelectComponentEventContext,
    MessageComponentEventContext,
    MessageCreateEventContext, MessageDeleteBulkEventContext, MessageDeleteEventContext, MessageReactionAddEventContext,
    MessageReactionRemoveAllEventContext, MessageReactionRemoveEmojiEventContext,
    MessageReactionRemoveEventContext, MessageUpdateEventContext, ModalSubmitEventContext,
    PrefixMessageEventContext, RoleSelectComponentEventContext, StringSelectComponentEventContext,
    UserSelectComponentEventContext,
    PresenceUpdateEventContext, ReadyEventContext, ResumedEventContext, ThreadCreateEventContext,
    ThreadDeleteEventContext, ThreadUpdateEventContext, TypingStartEventContext, UserUpdateEventContext,
    VoiceServerUpdateEventContext, VoiceStateUpdateEventContext, WebhooksUpdateEventContext;
import ddiscord.gateway.client : GatewayChannelPinsUpdateInfo, GatewayGuildBanInfo,
    GatewayGuildRoleDeleteInfo, GatewayGuildRoleInfo, GatewayInviteInfo, GatewayMessageDeleteBulkInfo,
    GatewayMessageDeleteInfo, GatewayMessageReactionInfo, GatewayMessageReactionRemoveAllInfo, GatewayThreadDeleteInfo,
    GatewayTypingStartInfo, GatewayVoiceServerUpdateInfo, GatewayVoiceStateUpdateInfo,
    GatewayWebhooksUpdateInfo;
import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild, UnavailableGuild;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.user : User;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.json : JSONValue;

mixin template ClientEventContextBuilders()
{
    private EventContext buildEventContext(
        Nullable!User user = Nullable!User.init,
        Nullable!Guild guild = Nullable!Guild.init,
        Nullable!GuildMember member = Nullable!GuildMember.init,
        Nullable!Channel channel = Nullable!Channel.init,
        Nullable!Message message = Nullable!Message.init,
        Nullable!Interaction interaction = Nullable!Interaction.init
    )
    {
        EventContext ctx;
        ctx.rest = rest;
        ctx.services = services;
        ctx.cache = cache;
        ctx.state = state;
        ctx.logger = logger;
        ctx.currentUser = user;
        ctx.currentGuild = guild;
        ctx.currentMember = member;
        ctx.currentChannel = channel;
        ctx.currentMessage = message;
        ctx.currentInteraction = interaction;
        return ctx;
    }

    private ReadyEventContext buildReadyEventContext(User selfUser)
    {
        ReadyEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(selfUser));
        ctx.selfUser = selfUser;
        return ctx;
    }

    private ResumedEventContext buildResumedEventContext(User selfUser)
    {
        ResumedEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(selfUser));
        ctx.selfUser = selfUser;
        return ctx;
    }

    private GuildCreateEventContext buildGuildCreateEventContext(Guild guild)
    {
        GuildCreateEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(_selfUser), Nullable!Guild.of(guild));
        ctx.guildData = guild;
        return ctx;
    }

    private GuildDeleteEventContext buildGuildDeleteEventContext(UnavailableGuild guild)
    {
        GuildDeleteEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(_selfUser), lookupGuild(Nullable!Snowflake.of(guild.id)));
        ctx.guildData = guild;
        return ctx;
    }

    private GuildUpdateEventContext buildGuildUpdateEventContext(Guild guild)
    {
        GuildUpdateEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(_selfUser), Nullable!Guild.of(guild));
        ctx.guildData = guild;
        return ctx;
    }

    private GuildMemberRemoveEventContext buildGuildMemberRemoveEventContext(
        User user,
        Nullable!Snowflake guildId
    )
    {
        GuildMemberRemoveEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(user), lookupGuild(guildId));
        ctx.userData = user;
        return ctx;
    }

    private GuildBanAddEventContext buildGuildBanAddEventContext(GatewayGuildBanInfo info)
    {
        GuildBanAddEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(info.user),
            lookupGuild(Nullable!Snowflake.of(info.guildId))
        );
        ctx.guildId = info.guildId;
        ctx.userData = info.user;
        return ctx;
    }

    private GuildBanRemoveEventContext buildGuildBanRemoveEventContext(GatewayGuildBanInfo info)
    {
        GuildBanRemoveEventContext ctx;
        auto built = buildGuildBanAddEventContext(info);
        ctx.event = built.event;
        ctx.guildId = built.guildId;
        ctx.userData = built.userData;
        return ctx;
    }

    private ChannelCreateEventContext buildChannelCreateEventContext(Channel channel)
    {
        ChannelCreateEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(channel.guildId),
            Nullable!GuildMember.init,
            nullableChannel(channel)
        );
        ctx.channelData = channel;
        return ctx;
    }

    private ChannelUpdateEventContext buildChannelUpdateEventContext(Channel channel)
    {
        ChannelUpdateEventContext ctx;
        ctx.event = buildChannelCreateEventContext(channel).event;
        ctx.channelData = channel;
        return ctx;
    }

    private ChannelDeleteEventContext buildChannelDeleteEventContext(Channel channel)
    {
        ChannelDeleteEventContext ctx;
        ctx.event = buildChannelCreateEventContext(channel).event;
        ctx.channelData = channel;
        return ctx;
    }

    private ChannelPinsUpdateEventContext buildChannelPinsUpdateEventContext(
        GatewayChannelPinsUpdateInfo info
    )
    {
        ChannelPinsUpdateEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannel(info.channelId)
        );
        ctx.channelId = info.channelId;
        ctx.guildId = info.guildId;
        ctx.lastPinTimestamp = info.lastPinTimestamp;
        return ctx;
    }

    private MessageCreateEventContext buildMessageCreateEventContext(Message message, Channel channel)
    {
        MessageCreateEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(message.author),
            lookupGuild(message.guildId),
            message.member,
            nullableChannel(channel),
            Nullable!Message.of(message)
        );
        ctx.message = message;
        return ctx;
    }

    private MessageUpdateEventContext buildMessageUpdateEventContext(Message message)
    {
        Channel channel;
        channel.id = message.channelId;
        if (!message.guildId.isNull)
            channel.guildId = message.guildId;

        MessageUpdateEventContext ctx;
        ctx.event = buildMessageCreateEventContext(message, channel).event;
        ctx.message = message;
        return ctx;
    }

    private MessageDeleteEventContext buildMessageDeleteEventContext(
        GatewayMessageDeleteInfo info,
        Nullable!Message cachedMessage
    )
    {
        MessageDeleteEventContext ctx;
        Nullable!User user;
        Nullable!GuildMember member;
        if (!cachedMessage.isNull)
        {
            user = Nullable!User.of(cachedMessage.get.author);
            member = cachedMessage.get.member;
        }

        Channel channel;
        if (!info.channelId.isNull)
            channel.id = info.channelId.get;

        ctx.event = buildEventContext(
            user,
            lookupGuild(info.guildId),
            member,
            nullableChannel(channel),
            cachedMessage
        );
        ctx.messageId = info.messageId;
        ctx.channelId = info.channelId;
        ctx.guildId = info.guildId;
        return ctx;
    }

    private MessageDeleteBulkEventContext buildMessageDeleteBulkEventContext(
        GatewayMessageDeleteBulkInfo info
    )
    {
        MessageDeleteBulkEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannelFromOptional(info.channelId)
        );
        ctx.messageIds = info.messageIds.dup;
        ctx.channelId = info.channelId;
        ctx.guildId = info.guildId;
        return ctx;
    }

    private MessageReactionAddEventContext buildMessageReactionAddEventContext(
        GatewayMessageReactionInfo info
    )
    {
        MessageReactionAddEventContext ctx;
        auto user = cache.user(info.userId);
        ctx.event = buildEventContext(
            user,
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannel(info.channelId),
            cache.message(info.messageId)
        );
        ctx.userId = info.userId;
        ctx.channelId = info.channelId;
        ctx.messageId = info.messageId;
        ctx.guildId = info.guildId;
        ctx.emojiName = info.emojiName;
        return ctx;
    }

    private MessageReactionRemoveEventContext buildMessageReactionRemoveEventContext(
        GatewayMessageReactionInfo info
    )
    {
        MessageReactionRemoveEventContext ctx;
        auto built = buildMessageReactionAddEventContext(info);
        ctx.event = built.event;
        ctx.userId = built.userId;
        ctx.channelId = built.channelId;
        ctx.messageId = built.messageId;
        ctx.guildId = built.guildId;
        ctx.emojiName = built.emojiName;
        return ctx;
    }

    private MessageReactionRemoveAllEventContext buildMessageReactionRemoveAllEventContext(
        GatewayMessageReactionRemoveAllInfo info
    )
    {
        MessageReactionRemoveAllEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannel(info.channelId),
            cache.message(info.messageId)
        );
        ctx.channelId = info.channelId;
        ctx.messageId = info.messageId;
        ctx.guildId = info.guildId;
        return ctx;
    }

    private MessageReactionRemoveEmojiEventContext buildMessageReactionRemoveEmojiEventContext(
        GatewayMessageReactionInfo info
    )
    {
        MessageReactionRemoveEmojiEventContext ctx;
        GatewayMessageReactionRemoveAllInfo removeAllInfo;
        removeAllInfo.channelId = info.channelId;
        removeAllInfo.messageId = info.messageId;
        removeAllInfo.guildId = info.guildId;
        auto removeAll = buildMessageReactionRemoveAllEventContext(removeAllInfo);
        ctx.event = removeAll.event;
        ctx.channelId = info.channelId;
        ctx.messageId = info.messageId;
        ctx.guildId = info.guildId;
        ctx.emojiName = info.emojiName;
        return ctx;
    }

    private InteractionCreateEventContext buildInteractionCreateEventContext(Interaction interaction, Channel channel)
    {
        InteractionCreateEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(interaction.user),
            lookupGuild(interaction.guildId),
            interaction.member,
            nullableChannel(channel),
            interaction.targetMessage,
            Nullable!Interaction.of(interaction)
        );
        ctx.interaction = interaction;
        return ctx;
    }

    private GuildMemberAddEventContext buildGuildMemberAddEventContext(
        GuildMember member,
        Nullable!Snowflake guildId
    )
    {
        GuildMemberAddEventContext ctx;
        Nullable!User user;
        if (!member.user.isNull)
            user = Nullable!User.of(member.user.get);
        ctx.event = buildEventContext(user, lookupGuild(guildId), Nullable!GuildMember.of(member));
        ctx.memberData = member;
        return ctx;
    }

    private AutocompleteInteractionEventContext buildAutocompleteInteractionEventContext(
        Interaction interaction,
        Channel channel
    )
    {
        AutocompleteInteractionEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        auto focused = focusedOption(interaction);
        if (!focused.isNull)
        {
            ctx.focusedName = focused.get.name;
            ctx.focusedValue = focused.get.value;
        }
        return ctx;
    }

    private MessageComponentEventContext buildMessageComponentEventContext(
        Interaction interaction,
        Channel channel
    )
    {
        MessageComponentEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        ctx.componentType = interaction.componentType;
        ctx.customId = interaction.customId;
        ctx.values = interaction.values.dup;
        ctx.submittedComponents = interaction.submittedComponents.dup;
        return ctx;
    }

    private ButtonComponentEventContext buildButtonComponentEventContext(
        Interaction interaction,
        Channel channel
    )
    {
        ButtonComponentEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        ctx.customId = interaction.customId;
        return ctx;
    }

    private StringSelectComponentEventContext buildStringSelectComponentEventContext(
        Interaction interaction,
        Channel channel
    )
    {
        StringSelectComponentEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        ctx.customId = interaction.customId;
        ctx.values = interaction.values.dup;
        return ctx;
    }

    private UserSelectComponentEventContext buildUserSelectComponentEventContext(
        Interaction interaction,
        Channel channel
    )
    {
        UserSelectComponentEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        ctx.customId = interaction.customId;
        ctx.values = interaction.values.dup;
        return ctx;
    }

    private RoleSelectComponentEventContext buildRoleSelectComponentEventContext(
        Interaction interaction,
        Channel channel
    )
    {
        RoleSelectComponentEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        ctx.customId = interaction.customId;
        ctx.values = interaction.values.dup;
        return ctx;
    }

    private MentionableSelectComponentEventContext buildMentionableSelectComponentEventContext(
        Interaction interaction,
        Channel channel
    )
    {
        MentionableSelectComponentEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        ctx.customId = interaction.customId;
        ctx.values = interaction.values.dup;
        return ctx;
    }

    private ChannelSelectComponentEventContext buildChannelSelectComponentEventContext(
        Interaction interaction,
        Channel channel
    )
    {
        ChannelSelectComponentEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        ctx.customId = interaction.customId;
        ctx.values = interaction.values.dup;
        return ctx;
    }

    private BotMentionEventContext buildBotMentionEventContext(Message message, Channel channel)
    {
        BotMentionEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(message.author),
            lookupGuild(message.guildId),
            message.member,
            nullableChannel(channel),
            Nullable!Message.of(message)
        );
        ctx.message = message;
        return ctx;
    }

    private PrefixMessageEventContext buildPrefixMessageEventContext(
        Message message,
        Channel channel,
        string commandName,
        string rawArguments,
        bool knownCommand
    )
    {
        PrefixMessageEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(message.author),
            lookupGuild(message.guildId),
            message.member,
            nullableChannel(channel),
            Nullable!Message.of(message)
        );
        ctx.message = message;
        ctx.commandName = commandName;
        ctx.rawArguments = rawArguments;
        ctx.knownCommand = knownCommand;
        return ctx;
    }

    private ModalSubmitEventContext buildModalSubmitEventContext(Interaction interaction, Channel channel)
    {
        ModalSubmitEventContext ctx;
        ctx.event = buildInteractionCreateEventContext(interaction, channel).event;
        ctx.interaction = interaction;
        ctx.submittedComponents = interaction.submittedComponents.dup;
        return ctx;
    }

    private PresenceUpdateEventContext buildPresenceUpdateEventContext(StatusType status, Activity activity)
    {
        return buildGatewayPresenceUpdateEventContext(
            status,
            activity,
            Nullable!User.of(_selfUser),
            Nullable!Snowflake.init,
            Nullable!GuildMember.init
        );
    }

    private UserUpdateEventContext buildUserUpdateEventContext(User user)
    {
        UserUpdateEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(user));
        ctx.userData = user;
        return ctx;
    }

    private VoiceStateUpdateEventContext buildVoiceStateUpdateEventContext(
        GatewayVoiceStateUpdateInfo info
    )
    {
        VoiceStateUpdateEventContext ctx;
        ctx.event = buildEventContext(
            cache.user(info.userId),
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannelFromOptional(info.channelId)
        );
        ctx.guildId = info.guildId;
        ctx.channelId = info.channelId;
        ctx.userId = info.userId;
        ctx.sessionId = info.sessionId;
        ctx.deaf = info.deaf;
        ctx.mute = info.mute;
        ctx.selfDeaf = info.selfDeaf;
        ctx.selfMute = info.selfMute;
        ctx.selfStream = info.selfStream;
        ctx.selfVideo = info.selfVideo;
        ctx.suppress = info.suppress;
        return ctx;
    }

    private VoiceServerUpdateEventContext buildVoiceServerUpdateEventContext(
        GatewayVoiceServerUpdateInfo info
    )
    {
        VoiceServerUpdateEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(_selfUser), lookupGuild(info.guildId));
        ctx.guildId = info.guildId;
        ctx.token = info.token;
        ctx.endpoint = info.endpoint;
        return ctx;
    }

    private GatewayDispatchEventContext buildGatewayDispatchEventContext(
        string eventName,
        JSONValue payload,
        Nullable!long sequence
    )
    {
        GatewayDispatchEventContext ctx;
        ctx.event = buildEventContext(Nullable!User.of(_selfUser));
        ctx.eventName = eventName;
        ctx.payload = payload;
        ctx.sequence = sequence;
        return ctx;
    }

    private Nullable!Channel lookupChannelFromOptional(Nullable!Snowflake channelId)
    {
        if (channelId.isNull)
            return Nullable!Channel.init;
        return lookupChannel(channelId.get);
    }

    private PresenceUpdateEventContext buildGatewayPresenceUpdateEventContext(
        StatusType status,
        Activity activity,
        Nullable!User user,
        Nullable!Snowflake guildId,
        Nullable!GuildMember member
    )
    {
        PresenceUpdateEventContext ctx;
        ctx.event = buildEventContext(user, lookupGuild(guildId), member);
        ctx.status = status;
        ctx.activity = activity;
        return ctx;
    }

    private TypingStartEventContext buildTypingStartEventContext(GatewayTypingStartInfo info)
    {
        TypingStartEventContext ctx;
        auto user = cache.user(info.userId);
        ctx.event = buildEventContext(
            user,
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannel(info.channelId)
        );
        ctx.channelId = info.channelId;
        ctx.guildId = info.guildId;
        ctx.userId = info.userId;
        ctx.timestampUnix = info.timestampUnix;
        return ctx;
    }

    private GuildRoleCreateEventContext buildGuildRoleCreateEventContext(GatewayGuildRoleInfo info)
    {
        GuildRoleCreateEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(Nullable!Snowflake.of(info.guildId))
        );
        ctx.guildId = info.guildId;
        ctx.roleData = info.role;
        return ctx;
    }

    private GuildRoleUpdateEventContext buildGuildRoleUpdateEventContext(GatewayGuildRoleInfo info)
    {
        GuildRoleUpdateEventContext ctx;
        auto built = buildGuildRoleCreateEventContext(info);
        ctx.event = built.event;
        ctx.guildId = built.guildId;
        ctx.roleData = built.roleData;
        return ctx;
    }

    private GuildRoleDeleteEventContext buildGuildRoleDeleteEventContext(
        GatewayGuildRoleDeleteInfo info
    )
    {
        GuildRoleDeleteEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(Nullable!Snowflake.of(info.guildId))
        );
        ctx.guildId = info.guildId;
        ctx.roleId = info.roleId;
        return ctx;
    }

    private InviteCreateEventContext buildInviteCreateEventContext(GatewayInviteInfo info)
    {
        InviteCreateEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannel(info.channelId)
        );
        ctx.code = info.code;
        ctx.channelId = info.channelId;
        ctx.guildId = info.guildId;
        return ctx;
    }

    private InviteDeleteEventContext buildInviteDeleteEventContext(GatewayInviteInfo info)
    {
        InviteDeleteEventContext ctx;
        auto built = buildInviteCreateEventContext(info);
        ctx.event = built.event;
        ctx.code = built.code;
        ctx.channelId = built.channelId;
        ctx.guildId = built.guildId;
        return ctx;
    }

    private WebhooksUpdateEventContext buildWebhooksUpdateEventContext(
        GatewayWebhooksUpdateInfo info
    )
    {
        WebhooksUpdateEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannel(info.channelId)
        );
        ctx.channelId = info.channelId;
        ctx.guildId = info.guildId;
        return ctx;
    }

    private ThreadCreateEventContext buildThreadCreateEventContext(Channel thread)
    {
        ThreadCreateEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(thread.guildId),
            Nullable!GuildMember.init,
            nullableChannel(thread)
        );
        ctx.threadData = thread;
        return ctx;
    }

    private ThreadUpdateEventContext buildThreadUpdateEventContext(Channel thread)
    {
        ThreadUpdateEventContext ctx;
        auto built = buildThreadCreateEventContext(thread);
        ctx.event = built.event;
        ctx.threadData = built.threadData;
        return ctx;
    }

    private ThreadDeleteEventContext buildThreadDeleteEventContext(GatewayThreadDeleteInfo info)
    {
        ThreadDeleteEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(_selfUser),
            lookupGuild(info.guildId),
            Nullable!GuildMember.init,
            lookupChannel(info.threadId)
        );
        ctx.threadId = info.threadId;
        ctx.guildId = info.guildId;
        ctx.parentId = info.parentId;
        return ctx;
    }

    private CommandExecutedEventContext buildCommandExecutedEventContext(
        CommandContext command,
        string commandName
    )
    {
        CommandExecutedEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(command.user),
            command.guild,
            command.member,
            nullableChannel(command.currentChannel),
            command.message,
            command.interaction
        );
        ctx.commandName = commandName;
        ctx.command = command;
        return ctx;
    }

    private CommandFailedEventContext buildCommandFailedEventContext(
        CommandContext command,
        string commandName
    )
    {
        CommandFailedEventContext ctx;
        ctx.event = buildEventContext(
            Nullable!User.of(command.user),
            command.guild,
            command.member,
            nullableChannel(command.currentChannel),
            command.message,
            command.interaction
        );
        ctx.commandName = commandName;
        ctx.command = command;
        return ctx;
    }

    private Nullable!Guild lookupGuild(Nullable!Snowflake guildId)
    {
        if (guildId.isNull)
            return Nullable!Guild.init;
        return cache.guild(guildId.get);
    }

    private Nullable!Channel lookupChannel(Snowflake channelId)
    {
        if (channelId.value == 0)
            return Nullable!Channel.init;
        return cache.channel(channelId);
    }

    private Nullable!Channel nullableChannel(Channel channel)
    {
        if (channel.id.value == 0)
            return Nullable!Channel.init;
        return Nullable!Channel.of(channel);
    }
}
