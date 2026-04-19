/**
 * ddiscord — permission calculation helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.permissions;

import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild;
import ddiscord.models.member : GuildMember;
import ddiscord.models.role : Permissions, Role;
import ddiscord.util.errors : DdiscordException, formatError;
import std.array : join;

/// Exception raised when a permission check fails.
final class MissingPermissionsException : DdiscordException
{
    Permissions[] missing;

    this(Permissions[] missing, string detail = "")
    {
        this.missing = missing.dup;
        super(formatError(
            "permissions",
            "The current principal is missing one or more required Discord permissions.",
            detail.length == 0 ? "Missing: " ~ permissionNames(missing).join(", ") ~ "." : detail,
            "Grant the missing permissions or relax the command or REST policy."
        ));
    }
}

/// Computes guild-level permissions before channel overwrites are applied.
ulong computeBasePermissions(GuildMember member, Guild guild, Role[] roles)
{
    if (!guild.ownerId.isNull && !member.user.isNull && guild.ownerId.get == member.user.get.id)
        return ulong.max;

    ulong permissions;

    foreach (role; roles)
    {
        if (role.id == guild.id)
        {
            permissions |= role.permissions;
            break;
        }
    }

    foreach (roleId; member.roleIds)
    {
        foreach (role; roles)
        {
            if (role.id == roleId)
                permissions |= role.permissions;
        }
    }

    if (hasPermission(permissions, cast(ulong) Permissions.Administrator))
        return ulong.max;

    return permissions;
}

/// Applies Discord channel overwrites in the correct order.
ulong computeOverwrites(ulong basePermissions, GuildMember member, Guild guild, Channel channel)
{
    if (basePermissions == ulong.max || channel.permissionOverwrites.length == 0)
        return basePermissions;

    ulong everyoneAllow;
    ulong everyoneDeny;
    ulong rolesAllow;
    ulong rolesDeny;
    ulong memberAllow;
    ulong memberDeny;

    foreach (overwrite; channel.permissionOverwrites)
    {
        if (overwrite.id == guild.id)
        {
            everyoneAllow |= overwrite.allow;
            everyoneDeny |= overwrite.deny;
            continue;
        }

        bool matchesRole = false;
        foreach (roleId; member.roleIds)
        {
            if (overwrite.id == roleId)
            {
                matchesRole = true;
                break;
            }
        }

        if (matchesRole)
        {
            rolesAllow |= overwrite.allow;
            rolesDeny |= overwrite.deny;
            continue;
        }

        if (!member.user.isNull && overwrite.id == member.user.get.id)
        {
            memberAllow |= overwrite.allow;
            memberDeny |= overwrite.deny;
        }
    }

    auto effective = basePermissions;
    effective = applyOverwrite(effective, everyoneAllow, everyoneDeny);
    effective = applyOverwrite(effective, rolesAllow, rolesDeny);
    effective = applyOverwrite(effective, memberAllow, memberDeny);
    return effective;
}

/// Computes effective permissions in a channel.
ulong computeEffectivePermissions(GuildMember member, Guild guild, Channel channel, Role[] roles)
{
    auto basePermissions = computeBasePermissions(member, guild, roles);
    return computeOverwrites(basePermissions, member, guild, channel);
}

/// Returns whether a mask contains every required permission bit.
bool hasPermission(ulong set, ulong required)
{
    return (set & required) == required;
}

/// Returns whether the member has the required permission in the channel.
bool hasPermissionIn(
    GuildMember member,
    Guild guild,
    Channel channel,
    Role[] roles,
    ulong required
)
{
    return hasPermission(computeEffectivePermissions(member, guild, channel, roles), required);
}

/// Lists the missing permission flags required by a mask.
Permissions[] missingPermissions(ulong provided, ulong required)
{
    Permissions[] missing;

    static foreach (memberName; __traits(allMembers, Permissions))
    {
        static if (memberName != "init" && memberName != "max" && memberName != "min" && memberName != "sizeof")
        {
            {
                enum permissionValue = mixin("Permissions." ~ memberName);
                if ((required & cast(ulong) permissionValue) != 0 && (provided & cast(ulong) permissionValue) == 0)
                    missing ~= permissionValue;
            }
        }
    }

    return missing;
}

/// Human-readable label for a permission flag.
string permissionName(Permissions permission)
{
    final switch (permission)
    {
        case Permissions.CreateInstantInvite:
            return "CreateInstantInvite";
        case Permissions.KickMembers:
            return "KickMembers";
        case Permissions.BanMembers:
            return "BanMembers";
        case Permissions.Administrator:
            return "Administrator";
        case Permissions.ManageChannels:
            return "ManageChannels";
        case Permissions.ManageGuild:
            return "ManageGuild";
        case Permissions.AddReactions:
            return "AddReactions";
        case Permissions.ViewAuditLog:
            return "ViewAuditLog";
        case Permissions.PrioritySpeaker:
            return "PrioritySpeaker";
        case Permissions.Stream:
            return "Stream";
        case Permissions.ViewChannel:
            return "ViewChannel";
        case Permissions.SendMessages:
            return "SendMessages";
        case Permissions.ManageMessages:
            return "ManageMessages";
        case Permissions.EmbedLinks:
            return "EmbedLinks";
        case Permissions.AttachFiles:
            return "AttachFiles";
        case Permissions.ReadMessageHistory:
            return "ReadMessageHistory";
        case Permissions.MentionEveryone:
            return "MentionEveryone";
        case Permissions.UseExternalEmojis:
            return "UseExternalEmojis";
        case Permissions.ManageRoles:
            return "ManageRoles";
        case Permissions.ManageWebhooks:
            return "ManageWebhooks";
        case Permissions.UseApplicationCommands:
            return "UseApplicationCommands";
        case Permissions.ManageEvents:
            return "ManageEvents";
        case Permissions.ManageThreads:
            return "ManageThreads";
        case Permissions.UseExternalStickers:
            return "UseExternalStickers";
        case Permissions.SendMessagesInThreads:
            return "SendMessagesInThreads";
        case Permissions.ModerateMembers:
            return "ModerateMembers";
    }
}

/// Human-readable labels for a permission list.
string[] permissionNames(Permissions[] permissions)
{
    string[] names;
    foreach (permission; permissions)
        names ~= permissionName(permission);
    return names;
}

private ulong applyOverwrite(ulong permissions, ulong allow, ulong deny)
{
    permissions &= ~deny;
    permissions |= allow;
    return permissions;
}

unittest
{
    import ddiscord.models.channel : PermissionOverwrite, PermissionOverwriteType;
    import ddiscord.models.user : User;
    import ddiscord.util.optional : Nullable;
    import ddiscord.util.snowflake : Snowflake;

    Guild guild;
    guild.id = Snowflake(1);
    guild.ownerId = Nullable!Snowflake.init;

    Role everyone;
    everyone.id = Snowflake(1);
    everyone.permissions = cast(ulong) Permissions.ViewChannel;

    Role writer;
    writer.id = Snowflake(2);
    writer.permissions = cast(ulong) Permissions.SendMessages;

    GuildMember member;
    User user;
    user.id = Snowflake(9);
    member.user = Nullable!User.of(user);
    member.roleIds = [Snowflake(2)];

    Channel channel;
    channel.id = Snowflake(7);

    auto effective = computeEffectivePermissions(member, guild, channel, [everyone, writer]);
    assert(hasPermission(effective, cast(ulong) Permissions.ViewChannel));
    assert(hasPermission(effective, cast(ulong) Permissions.SendMessages));

    PermissionOverwrite overwrite;
    overwrite.id = Snowflake(2);
    overwrite.kind = PermissionOverwriteType.Role;
    overwrite.deny = cast(ulong) Permissions.SendMessages;
    channel.permissionOverwrites = [overwrite];

    effective = computeEffectivePermissions(member, guild, channel, [everyone, writer]);
    assert(!hasPermission(effective, cast(ulong) Permissions.SendMessages));
    assert(missingPermissions(effective, cast(ulong) Permissions.SendMessages) == [Permissions.SendMessages]);
}
