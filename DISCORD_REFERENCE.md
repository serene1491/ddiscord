# 📡 DISCORD_REFERENCE.md — Complete Discord API Reference for ddiscord

> Source of truth for all Discord types, events, constants, and opcodes.
> Every item here must be implemented. Nothing may be skipped.

---

## 1. Gateway Opcodes

```d
module ddiscord.core.gateway.opcodes;

enum GatewayOpcode : int
{
    Dispatch              = 0,   // Server → Client: event dispatch
    Heartbeat             = 1,   // Both: heartbeat
    Identify              = 2,   // Client → Server: authenticate
    PresenceUpdate        = 3,   // Client → Server: update presence
    VoiceStateUpdate      = 4,   // Client → Server: update voice state
    Resume                = 6,   // Client → Server: resume session
    Reconnect             = 7,   // Server → Client: reconnect
    RequestGuildMembers   = 8,   // Client → Server: request members
    InvalidSession        = 9,   // Server → Client: session invalidated
    Hello                 = 10,  // Server → Client: hello + heartbeat_interval
    HeartbeatAck          = 11,  // Server → Client: heartbeat acknowledged
    RequestSoundboardSounds = 31, // Client → Server
}
```

---

## 2. Gateway Close Codes

```d
enum GatewayCloseCode : int
{
    // Resumable
    UnknownError         = 4000,
    UnknownOpcode        = 4001,
    DecodeError          = 4002,
    NotAuthenticated     = 4003,
    AlreadyAuthenticated = 4005,
    InvalidSeq           = 4007,
    RateLimited          = 4008,
    SessionTimedOut      = 4009,

    // Non-resumable (must re-identify)
    AuthenticationFailed = 4004,
    InvalidShard         = 4010,
    ShardingRequired     = 4011,
    InvalidApiVersion    = 4012,
    InvalidIntents       = 4013,
    DisallowedIntents    = 4014,
}

bool isResumable(GatewayCloseCode code) pure
{
    return code != GatewayCloseCode.AuthenticationFailed
        && code != GatewayCloseCode.InvalidShard
        && code != GatewayCloseCode.ShardingRequired
        && code != GatewayCloseCode.InvalidApiVersion
        && code != GatewayCloseCode.InvalidIntents
        && code != GatewayCloseCode.DisallowedIntents;
}
```

---

## 3. Gateway Intents

```d
enum GatewayIntent : uint
{
    // Privileged
    GuildPresences             = 1 << 8,
    GuildMembers               = 1 << 1,
    MessageContent             = 1 << 15,

    // Standard
    Guilds                     = 1 << 0,
    GuildModeration            = 1 << 2,
    GuildEmojisAndStickers     = 1 << 3,
    GuildIntegrations          = 1 << 4,
    GuildWebhooks              = 1 << 5,
    GuildInvites               = 1 << 6,
    GuildVoiceStates           = 1 << 7,
    GuildMessages              = 1 << 9,
    GuildMessageReactions      = 1 << 10,
    GuildMessageTyping         = 1 << 11,
    DirectMessages             = 1 << 12,
    DirectMessageReactions     = 1 << 13,
    DirectMessageTyping        = 1 << 14,
    GuildScheduledEvents       = 1 << 16,
    AutoModerationConfiguration = 1 << 20,
    AutoModerationExecution    = 1 << 21,
    GuildMessagePolls          = 1 << 24,
    DirectMessagePolls         = 1 << 25,
}

enum GatewayIntent AllNonPrivileged = /* bitwise OR of all non-privileged intents */;
enum GatewayIntent AllPrivileged = GatewayIntent.GuildPresences | GatewayIntent.GuildMembers | GatewayIntent.MessageContent;
enum GatewayIntent All = AllNonPrivileged | AllPrivileged;
```

---

## 4. All Gateway Events

Each event maps to a D struct in `ddiscord.events.*`.

### 4.1 Connection Events

| Gateway Name | D Event Type | Fired When |
|---|---|---|
| `READY` | `ReadyEvent` | Initial connection established |
| `RESUMED` | `ResumedEvent` | Session successfully resumed |

```d
struct ReadyEvent : BaseEvent
{
    int gatewayVersion;
    User selfUser;
    UnavailableGuild[] guilds;
    string sessionId;
    string resumeGatewayUrl;
    Nullable!Shard shard;
    Application application;
}

struct ResumedEvent : BaseEvent {}
```

---

### 4.2 Application Events

| Gateway Name | D Event Type |
|---|---|
| `APPLICATION_COMMAND_PERMISSIONS_UPDATE` | `ApplicationCommandPermissionsUpdateEvent` |

---

### 4.3 AutoMod Events

| Gateway Name | D Event Type |
|---|---|
| `AUTO_MODERATION_RULE_CREATE` | `AutoModerationRuleCreateEvent` |
| `AUTO_MODERATION_RULE_UPDATE` | `AutoModerationRuleUpdateEvent` |
| `AUTO_MODERATION_RULE_DELETE` | `AutoModerationRuleDeleteEvent` |
| `AUTO_MODERATION_ACTION_EXECUTION` | `AutoModerationActionExecutionEvent` |

---

### 4.4 Channel Events

| Gateway Name | D Event Type |
|---|---|
| `CHANNEL_CREATE` | `ChannelCreateEvent` |
| `CHANNEL_UPDATE` | `ChannelUpdateEvent` |
| `CHANNEL_DELETE` | `ChannelDeleteEvent` |
| `CHANNEL_PINS_UPDATE` | `ChannelPinsUpdateEvent` |

---

### 4.5 Thread Events

| Gateway Name | D Event Type |
|---|---|
| `THREAD_CREATE` | `ThreadCreateEvent` |
| `THREAD_UPDATE` | `ThreadUpdateEvent` |
| `THREAD_DELETE` | `ThreadDeleteEvent` |
| `THREAD_LIST_SYNC` | `ThreadListSyncEvent` |
| `THREAD_MEMBER_UPDATE` | `ThreadMemberUpdateEvent` |
| `THREAD_MEMBERS_UPDATE` | `ThreadMembersUpdateEvent` |

---

### 4.6 Entitlement Events

| Gateway Name | D Event Type |
|---|---|
| `ENTITLEMENT_CREATE` | `EntitlementCreateEvent` |
| `ENTITLEMENT_UPDATE` | `EntitlementUpdateEvent` |
| `ENTITLEMENT_DELETE` | `EntitlementDeleteEvent` |

---

### 4.7 Guild Events

| Gateway Name | D Event Type |
|---|---|
| `GUILD_CREATE` | `GuildCreateEvent` |
| `GUILD_UPDATE` | `GuildUpdateEvent` |
| `GUILD_DELETE` | `GuildDeleteEvent` |
| `GUILD_AUDIT_LOG_ENTRY_CREATE` | `GuildAuditLogEntryCreateEvent` |
| `GUILD_BAN_ADD` | `GuildBanAddEvent` |
| `GUILD_BAN_REMOVE` | `GuildBanRemoveEvent` |
| `GUILD_EMOJIS_UPDATE` | `GuildEmojisUpdateEvent` |
| `GUILD_STICKERS_UPDATE` | `GuildStickersUpdateEvent` |
| `GUILD_INTEGRATIONS_UPDATE` | `GuildIntegrationsUpdateEvent` |
| `GUILD_MEMBER_ADD` | `GuildMemberAddEvent` |
| `GUILD_MEMBER_REMOVE` | `GuildMemberRemoveEvent` |
| `GUILD_MEMBER_UPDATE` | `GuildMemberUpdateEvent` |
| `GUILD_MEMBERS_CHUNK` | `GuildMembersChunkEvent` |
| `GUILD_ROLE_CREATE` | `GuildRoleCreateEvent` |
| `GUILD_ROLE_UPDATE` | `GuildRoleUpdateEvent` |
| `GUILD_ROLE_DELETE` | `GuildRoleDeleteEvent` |
| `GUILD_SCHEDULED_EVENT_CREATE` | `GuildScheduledEventCreateEvent` |
| `GUILD_SCHEDULED_EVENT_UPDATE` | `GuildScheduledEventUpdateEvent` |
| `GUILD_SCHEDULED_EVENT_DELETE` | `GuildScheduledEventDeleteEvent` |
| `GUILD_SCHEDULED_EVENT_USER_ADD` | `GuildScheduledEventUserAddEvent` |
| `GUILD_SCHEDULED_EVENT_USER_REMOVE` | `GuildScheduledEventUserRemoveEvent` |
| `GUILD_SOUNDBOARD_SOUND_CREATE` | `GuildSoundboardSoundCreateEvent` |
| `GUILD_SOUNDBOARD_SOUND_UPDATE` | `GuildSoundboardSoundUpdateEvent` |
| `GUILD_SOUNDBOARD_SOUND_DELETE` | `GuildSoundboardSoundDeleteEvent` |
| `GUILD_SOUNDBOARD_SOUNDS_UPDATE` | `GuildSoundboardSoundsUpdateEvent` |

---

### 4.8 Integration Events

| Gateway Name | D Event Type |
|---|---|
| `INTEGRATION_CREATE` | `IntegrationCreateEvent` |
| `INTEGRATION_UPDATE` | `IntegrationUpdateEvent` |
| `INTEGRATION_DELETE` | `IntegrationDeleteEvent` |

---

### 4.9 Interaction Event

| Gateway Name | D Event Type |
|---|---|
| `INTERACTION_CREATE` | `InteractionCreateEvent` |

This is the most important event. The `InteractionCreateEvent` carries an `Interaction` which is polymorphic by `InteractionType`.

---

### 4.10 Invite Events

| Gateway Name | D Event Type |
|---|---|
| `INVITE_CREATE` | `InviteCreateEvent` |
| `INVITE_DELETE` | `InviteDeleteEvent` |

---

### 4.11 Message Events

| Gateway Name | D Event Type |
|---|---|
| `MESSAGE_CREATE` | `MessageCreateEvent` |
| `MESSAGE_UPDATE` | `MessageUpdateEvent` |
| `MESSAGE_DELETE` | `MessageDeleteEvent` |
| `MESSAGE_DELETE_BULK` | `MessageDeleteBulkEvent` |
| `MESSAGE_REACTION_ADD` | `MessageReactionAddEvent` |
| `MESSAGE_REACTION_REMOVE` | `MessageReactionRemoveEvent` |
| `MESSAGE_REACTION_REMOVE_ALL` | `MessageReactionRemoveAllEvent` |
| `MESSAGE_REACTION_REMOVE_EMOJI` | `MessageReactionRemoveEmojiEvent` |

---

### 4.12 Poll Events

| Gateway Name | D Event Type |
|---|---|
| `MESSAGE_POLL_VOTE_ADD` | `MessagePollVoteAddEvent` |
| `MESSAGE_POLL_VOTE_REMOVE` | `MessagePollVoteRemoveEvent` |

---

### 4.13 Presence & User Events

| Gateway Name | D Event Type |
|---|---|
| `PRESENCE_UPDATE` | `PresenceUpdateEvent` |
| `USER_UPDATE` | `UserUpdateEvent` |
| `TYPING_START` | `TypingStartEvent` |

---

### 4.14 Stage Events

| Gateway Name | D Event Type |
|---|---|
| `STAGE_INSTANCE_CREATE` | `StageInstanceCreateEvent` |
| `STAGE_INSTANCE_UPDATE` | `StageInstanceUpdateEvent` |
| `STAGE_INSTANCE_DELETE` | `StageInstanceDeleteEvent` |

---

### 4.15 Subscription Events

| Gateway Name | D Event Type |
|---|---|
| `SUBSCRIPTION_CREATE` | `SubscriptionCreateEvent` |
| `SUBSCRIPTION_UPDATE` | `SubscriptionUpdateEvent` |
| `SUBSCRIPTION_DELETE` | `SubscriptionDeleteEvent` |

---

### 4.16 Voice Events

| Gateway Name | D Event Type |
|---|---|
| `VOICE_CHANNEL_EFFECT_SEND` | `VoiceChannelEffectSendEvent` |
| `VOICE_STATE_UPDATE` | `VoiceStateUpdateEvent` |
| `VOICE_SERVER_UPDATE` | `VoiceServerUpdateEvent` |

---

### 4.17 Webhook Events

| Gateway Name | D Event Type |
|---|---|
| `WEBHOOKS_UPDATE` | `WebhooksUpdateEvent` |

---

## 5. Interaction Types

```d
enum InteractionType : int
{
    Ping                           = 1,
    ApplicationCommand             = 2,
    MessageComponent               = 3,
    ApplicationCommandAutocomplete = 4,
    ModalSubmit                    = 5,
}
```

---

## 6. Application Command Types

```d
enum ApplicationCommandType : int
{
    ChatInput   = 1, // Slash commands — /name
    User        = 2, // User context menu
    Message     = 3, // Message context menu
}
```

---

## 7. Application Command Option Types

```d
enum ApplicationCommandOptionType : int
{
    SubCommand      = 1,
    SubCommandGroup = 2,
    String          = 3,
    Integer         = 4,
    Boolean         = 5,
    User            = 6,
    Channel         = 7,
    Role            = 8,
    Mentionable     = 9,   // User OR Role
    Number          = 10,  // float/double
    Attachment      = 11,
}
```

### Option argument D types

| OptionType | D Parameter Type |
|---|---|
| `String` | `string` |
| `Integer` | `long` |
| `Boolean` | `bool` |
| `Number` | `double` |
| `User` | `User` |
| `Channel` | `Channel` |
| `Role` | `Role` |
| `Mentionable` | `SumType!(User, Role)` |
| `Attachment` | `Attachment` |
| `SubCommand` | Resolved as a nested command handler |
| Autocomplete | `string` via `@Autocomplete!handler` |

Binding options in a command handler:
```d
@HybridCommand("upload")
void handleUpload(
    CommandContext ctx,
    @Option("username", "Visible username") string username,
    @Option("target", "Member to notify") User target,
    @Option("channel", "Where to send it") Nullable!Channel channel = Nullable!Channel.init,
    @Option("count", "Retry count") long count = 1L,
    @Option("ratio", "Sampling ratio") double ratio = 1.0,
    @Option("file", "Attachment to upload") Attachment file
)
{
    ...
}
```

---

## 8. Channel Types

```d
enum ChannelType : int
{
    GuildText            = 0,
    DM                   = 1,
    GuildVoice           = 2,
    GroupDM              = 3,
    GuildCategory        = 4,
    GuildAnnouncement    = 5,
    AnnouncementThread   = 10,
    PublicThread         = 11,
    PrivateThread        = 12,
    GuildStageVoice      = 13,
    GuildDirectory       = 14,
    GuildForum           = 15,
    GuildMedia           = 16,
}
```

---

## 9. Message Types

```d
enum MessageType : int
{
    Default                                      = 0,
    RecipientAdd                                 = 1,
    RecipientRemove                              = 2,
    Call                                         = 3,
    ChannelNameChange                            = 4,
    ChannelIconChange                            = 5,
    ChannelPinnedMessage                         = 6,
    UserJoin                                     = 7,
    GuildBoost                                   = 8,
    GuildBoostTier1                              = 9,
    GuildBoostTier2                              = 10,
    GuildBoostTier3                              = 11,
    ChannelFollowAdd                             = 12,
    GuildDiscoveryDisqualified                   = 14,
    GuildDiscoveryRequalified                    = 15,
    GuildDiscoveryGracePeriodInitialWarning      = 16,
    GuildDiscoveryGracePeriodFinalWarning        = 17,
    ThreadCreated                                = 18,
    Reply                                        = 19,
    ChatInputCommand                             = 20,
    ThreadStarterMessage                         = 21,
    GuildInviteReminder                          = 22,
    ContextMenuCommand                           = 23,
    AutoModerationAction                         = 24,
    RoleSubscriptionPurchase                     = 25,
    InteractionPremiumUpsell                     = 26,
    StageStart                                   = 27,
    StageEnd                                     = 28,
    StageSpeaker                                 = 29,
    StageTopic                                   = 31,
    GuildApplicationPremiumSubscription          = 32,
    GuildIncidentAlertModeEnabled                = 36,
    GuildIncidentAlertModeDisabled               = 37,
    GuildIncidentReportRaid                      = 38,
    GuildIncidentReportFalseAlarm                = 39,
    PurchaseNotification                         = 44,
    PollResult                                   = 46,
}
```

---

## 10. Message Flags

```d
enum MessageFlags : uint
{
    Crossposted                            = 1 << 0,
    IsCrosspost                            = 1 << 1,
    SuppressEmbeds                         = 1 << 2,
    SourceMessageDeleted                   = 1 << 3,
    Urgent                                 = 1 << 4,
    HasThread                              = 1 << 5,
    Ephemeral                              = 1 << 6,
    Loading                                = 1 << 7,
    FailedToMentionSomeRolesInThread       = 1 << 8,
    SuppressNotifications                  = 1 << 12,
    IsVoiceMessage                         = 1 << 13,
    IsComponentsV2                         = 1 << 15,  // ← required for components v2
}
```

---

## 11. Component Types

```d
enum ComponentType : int
{
    // Legacy
    ActionRow    = 1,
    Button       = 2,
    StringSelect = 3,
    TextInput    = 4,
    UserSelect   = 5,
    RoleSelect   = 6,
    MentionableSelect = 7,
    ChannelSelect = 8,

    // V2
    Section      = 9,
    TextDisplay  = 10,
    Thumbnail    = 11,
    MediaGallery = 12,
    File         = 13,
    Separator    = 14,
    ContentInventory = 16,
    Container    = 17,
}
```

---

## 12. Button Styles

```d
enum ButtonStyle : int
{
    Primary   = 1, // blurple
    Secondary = 2, // grey
    Success   = 3, // green
    Danger    = 4, // red
    Link      = 5, // grey, opens URL
    Premium   = 6, // blurple, opens premium subscription
}
```

---

## 13. Text Input Styles

```d
enum TextInputStyle : int
{
    Short     = 1, // single line
    Paragraph = 2, // multi-line
}
```

---

## 14. Interaction Callback Types

```d
enum InteractionCallbackType : int
{
    Pong                                    = 1,
    ChannelMessageWithSource               = 4,
    DeferredChannelMessageWithSource       = 5,
    DeferredUpdateMessage                  = 6,
    UpdateMessage                          = 7,
    ApplicationCommandAutocompleteResult   = 8,
    Modal                                  = 9,
    PremiumRequired                        = 10,  // deprecated
    LaunchActivity                         = 12,
}
```

---

## 15. Permissions (full list)

```d
enum Permissions : ulong
{
    CreateInstantInvite             = 1UL << 0,
    KickMembers                     = 1UL << 1,
    BanMembers                      = 1UL << 2,
    Administrator                   = 1UL << 3,
    ManageChannels                  = 1UL << 4,
    ManageGuild                     = 1UL << 5,
    AddReactions                    = 1UL << 6,
    ViewAuditLog                    = 1UL << 7,
    PrioritySpeaker                 = 1UL << 8,
    Stream                          = 1UL << 9,
    ViewChannel                     = 1UL << 10,
    SendMessages                    = 1UL << 11,
    SendTtsMessages                 = 1UL << 12,
    ManageMessages                  = 1UL << 13,
    EmbedLinks                      = 1UL << 14,
    AttachFiles                     = 1UL << 15,
    ReadMessageHistory              = 1UL << 16,
    MentionEveryone                 = 1UL << 17,
    UseExternalEmojis               = 1UL << 18,
    ViewGuildInsights               = 1UL << 19,
    Connect                         = 1UL << 20,
    Speak                           = 1UL << 21,
    MuteMembers                     = 1UL << 22,
    DeafenMembers                   = 1UL << 23,
    MoveMembers                     = 1UL << 24,
    UseVad                          = 1UL << 25,
    ChangeNickname                  = 1UL << 26,
    ManageNicknames                 = 1UL << 27,
    ManageRoles                     = 1UL << 28,
    ManageWebhooks                  = 1UL << 29,
    ManageGuildExpressions          = 1UL << 30,
    UseApplicationCommands          = 1UL << 31,
    RequestToSpeak                  = 1UL << 32,
    ManageEvents                    = 1UL << 33,
    ManageThreads                   = 1UL << 34,
    CreatePublicThreads             = 1UL << 35,
    CreatePrivateThreads            = 1UL << 36,
    UseExternalStickers             = 1UL << 37,
    SendMessagesInThreads           = 1UL << 38,
    UseEmbeddedActivities           = 1UL << 39,
    ModerateMembers                 = 1UL << 40, // timeout
    ViewCreatorMonetizationAnalytics = 1UL << 41,
    UseSoundboard                   = 1UL << 42,
    CreateGuildExpressions          = 1UL << 43,
    CreateEvents                    = 1UL << 44,
    UseExternalSounds               = 1UL << 45,
    SendVoiceMessages               = 1UL << 46,
    SendPolls                       = 1UL << 49,
    UseExternalApps                 = 1UL << 50,
}
```

---

## 16. Embed Limits

```d
module ddiscord.util.limits;

enum EMBED_TITLE_MAX         = 256;
enum EMBED_DESCRIPTION_MAX   = 4096;
enum EMBED_FIELDS_MAX        = 25;
enum EMBED_FIELD_NAME_MAX    = 256;
enum EMBED_FIELD_VALUE_MAX   = 1024;
enum EMBED_FOOTER_TEXT_MAX   = 2048;
enum EMBED_AUTHOR_NAME_MAX   = 256;
enum EMBED_TOTAL_CHARS_MAX   = 6000; // sum of all text fields across all embeds

enum MESSAGE_CONTENT_MAX     = 2000;
enum MESSAGE_EMBEDS_MAX      = 10;
enum MESSAGE_FILES_MAX       = 10;
enum MESSAGE_COMPONENTS_MAX  = 5;    // action rows
enum ACTION_ROW_COMPONENTS_MAX = 5;  // buttons/selects per row

enum MODAL_TITLE_MAX         = 45;
enum MODAL_COMPONENTS_MAX    = 5;
enum TEXT_INPUT_LABEL_MAX    = 45;
enum TEXT_INPUT_VALUE_MAX    = 4000;
enum TEXT_INPUT_PLACEHOLDER_MAX = 100;

enum SELECT_OPTIONS_MAX      = 25;
enum SELECT_PLACEHOLDER_MAX  = 150;

enum AUTOCOMPLETE_CHOICES_MAX = 25;
enum CHOICE_NAME_MAX         = 100;
enum CHOICE_VALUE_MAX        = 100;

enum SLASH_COMMAND_NAME_MAX       = 32;
enum SLASH_COMMAND_DESCRIPTION_MAX = 100;
enum SLASH_COMMAND_OPTIONS_MAX    = 25;

enum GUILD_NAME_MIN = 2;
enum GUILD_NAME_MAX = 100;

enum USERNAME_MIN = 2;
enum USERNAME_MAX = 32;

enum BULK_DELETE_MIN = 2;
enum BULK_DELETE_MAX = 100;
enum BULK_DELETE_MAX_AGE_DAYS = 14; // messages older than 14 days cannot be bulk deleted

enum RATE_LIMIT_GLOBAL_PER_SECOND = 50;
enum GATEWAY_VERSION = 10;
enum API_VERSION = 10;
```

---

## 17. Presence / Activity Types

```d
enum ActivityType : int
{
    Playing    = 0, // "Playing {name}"
    Streaming  = 1, // "Streaming {details}"
    Listening  = 2, // "Listening to {name}"
    Watching   = 3, // "Watching {name}"
    Custom     = 4, // "{emoji} {state}"
    Competing  = 5, // "Competing in {name}"
}

enum StatusType : string
{
    Online       = "online",
    Idle         = "idle",
    DoNotDisturb = "dnd",
    Invisible    = "invisible",
    Offline      = "offline",
}
```

---

## 18. Premium Types

```d
enum PremiumType : int
{
    None         = 0,
    NitroClassic = 1,
    Nitro        = 2,
    NitroBasic   = 3,
}
```

---

## 19. Verification Level

```d
enum VerificationLevel : int
{
    None      = 0,
    Low       = 1,
    Medium    = 2,
    High      = 3,
    VeryHigh  = 4,
}
```

---

## 20. Image Formats

```d
enum ImageFormat : string
{
    PNG  = "png",
    JPEG = "jpg",
    WebP = "webp",
    GIF  = "gif",
    Lottie = "json", // only for stickers
}
```

---

## 21. Allowed Mention Types

```d
enum AllowedMentionType : string
{
    Roles    = "roles",
    Users    = "users",
    Everyone = "everyone",
}
```

---

## 22. Scheduled Event Entity Types

```d
enum ScheduledEventEntityType : int
{
    StageInstance = 1,
    Voice         = 2,
    External      = 3,
}

enum ScheduledEventStatus : int
{
    Scheduled = 1,
    Active    = 2,
    Completed = 3,
    Canceled  = 4,
}
```

---

## 23. AutoMod Trigger Types

```d
enum AutoModTriggerType : int
{
    Keyword        = 1,
    Spam           = 3,
    KeywordPreset  = 4,
    MentionSpam    = 5,
    MemberProfile  = 6,
}

enum AutoModActionType : int
{
    BlockMessage         = 1,
    SendAlertMessage     = 2,
    Timeout              = 3,
    BlockMemberInteraction = 4,
}
```

---

## 24. Snowflake Utilities

```d
module ddiscord.util.snowflake;

/// Discord Epoch: 2015-01-01T00:00:00.000Z as Unix milliseconds
enum DISCORD_EPOCH = 1_420_070_400_000UL;

struct Snowflake
{
    private ulong _value;

    this(ulong value) pure @safe { _value = value; }

    ulong toULong() const pure @safe @nogc { return _value; }
    string toString() const pure @safe { return _value.to!string; }

    /// Extract the creation timestamp from the Snowflake
    SysTime createdAt() const @safe
    {
        ulong ms = (_value >> 22) + DISCORD_EPOCH;
        return SysTime(unixTimeToStdTime(ms / 1000));
    }

    /// Extract the worker ID (bits 17–21)
    ubyte workerId() const pure @safe @nogc
    {
        return cast(ubyte)((_value & 0x3E0000) >> 17);
    }

    /// Extract the process ID (bits 12–16)
    ubyte processId() const pure @safe @nogc
    {
        return cast(ubyte)((_value & 0x1F000) >> 12);
    }

    /// Extract the increment (bits 0–11)
    ushort increment() const pure @safe @nogc
    {
        return cast(ushort)(_value & 0xFFF);
    }

    bool opEquals(const Snowflake other) const pure @safe @nogc
    {
        return _value == other._value;
    }

    int opCmp(const Snowflake other) const pure @safe @nogc
    {
        return _value < other._value ? -1 : (_value > other._value ? 1 : 0);
    }
}
```
