module store;

import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import dorm.api.condition : Condition;
import dorm.api.db;
import models : SavedScript;
import std.algorithm : sort;
import std.ascii : isAlphaNum, toLower;
import std.string : strip;
import StdTypecons = std.typecons;

mixin SetupDormRuntime;

enum MaxScriptNameLength = 32;
enum MaxScriptSourceLength = 6_000;

enum ScriptScope
{
    user,
    server,
}

@DormPatch!SavedScript
struct NewSavedScript
{
    string name;
    string scopeType;
    long ownerUserId;
    StdTypecons.Nullable!long guildId;
    string source;
}

final class ScriptStore
{
    private DormDB _db;

    this(string path)
    {
        _db = DormDB(DBConnectOptions(SQLiteConnectOptions(filename: path)));
    }

    Result!(SavedScript, string) create(
        string rawScope,
        string rawName,
        string rawSource,
        Snowflake ownerUserId,
        Nullable!Snowflake guildId
    )
    {
        auto parsedScope = parseScope(rawScope);
        if (parsedScope.isErr)
            return Result!(SavedScript, string).err(parsedScope.error);

        auto name = normalizeName(rawName);
        if (name.isErr)
            return Result!(SavedScript, string).err(name.error);

        auto source = normalizeSource(rawSource);
        if (source.isErr)
            return Result!(SavedScript, string).err(source.error);

        auto dbGuildId = normalizeGuild(parsedScope.value, guildId);
        if (dbGuildId.isErr)
            return Result!(SavedScript, string).err(dbGuildId.error);

        if (existsForCreate(parsedScope.value, name.value, ownerUserId, dbGuildId.value))
        {
            return Result!(SavedScript, string).err(
                "A " ~ scopeName(parsedScope.value) ~ " script named `" ~ name.value ~ "` already exists."
            );
        }

        NewSavedScript record;
        record.name = name.value;
        record.scopeType = scopeName(parsedScope.value);
        record.ownerUserId = cast(long) ownerUserId.value;
        record.guildId = dbGuildId.value;
        record.source = source.value;
        _db.insert(record);

        return owned(parsedScope.value, name.value, ownerUserId, guildId);
    }

    Result!(SavedScript, string) update(
        string rawScope,
        string rawName,
        string rawSource,
        Snowflake ownerUserId,
        Nullable!Snowflake guildId
    )
    {
        auto current = ownedByName(rawScope, rawName, ownerUserId, guildId);
        if (current.isErr)
            return current;

        auto source = normalizeSource(rawSource);
        if (source.isErr)
            return Result!(SavedScript, string).err(source.error);

        _db.update!SavedScript
            .set!"source"(source.value)
            .condition((script) => script.id.equals(current.value.id))
            .await;

        return owned(parseScope(rawScope).value, current.value.name, ownerUserId, guildId);
    }

    Result!(SavedScript, string) ownedByName(
        string rawScope,
        string rawName,
        Snowflake ownerUserId,
        Nullable!Snowflake guildId
    )
    {
        auto parsedScope = parseScope(rawScope);
        if (parsedScope.isErr)
            return Result!(SavedScript, string).err(parsedScope.error);

        auto name = normalizeName(rawName);
        if (name.isErr)
            return Result!(SavedScript, string).err(name.error);

        return owned(parsedScope.value, name.value, ownerUserId, guildId);
    }

    Result!(SavedScript, string) show(
        string rawScope,
        string rawName,
        Snowflake requesterUserId,
        Nullable!Snowflake guildId
    )
    {
        auto parsedScope = parseScope(rawScope);
        if (parsedScope.isErr)
            return Result!(SavedScript, string).err(parsedScope.error);

        auto name = normalizeName(rawName);
        if (name.isErr)
            return Result!(SavedScript, string).err(name.error);

        SavedScript script;

        if (parsedScope.value == ScriptScope.user)
        {
            auto found = findUserScript(name.value, requesterUserId);
            if (found.isNull)
                return Result!(SavedScript, string).err("You do not have a user script named `" ~ name.value ~ "`.");
            script = found.get;
        }
        else
        {
            auto dbGuildId = normalizeGuild(parsedScope.value, guildId);
            if (dbGuildId.isErr)
                return Result!(SavedScript, string).err(dbGuildId.error);

            auto found = findGuildScript(name.value, dbGuildId.value.get);
            if (found.isNull)
            {
                return Result!(SavedScript, string).err(
                    "This server does not have a shared script named `" ~ name.value ~ "`."
                );
            }
            script = found.get;
        }

        return Result!(SavedScript, string).ok(script);
    }

    Result!(bool, string) remove(
        string rawScope,
        string rawName,
        Snowflake ownerUserId,
        Nullable!Snowflake guildId
    )
    {
        auto current = ownedByName(rawScope, rawName, ownerUserId, guildId);
        if (current.isErr)
            return Result!(bool, string).err(current.error);

        _db.remove(current.value);
        return Result!(bool, string).ok(true);
    }

    Result!(SavedScript[], string) listAvailable(Snowflake requesterUserId, Nullable!Snowflake guildId)
    {
        SavedScript[] scripts;
        Condition delegate(ConditionBuilder!SavedScript) @safe userCondition;
        userCondition = (ConditionBuilder!SavedScript script) @safe => Condition.and(
            script.scopeType.equals(scopeName(ScriptScope.user)),
            script.ownerUserId.equals(cast(long) requesterUserId.value)
        );

        scripts ~= _db.select!SavedScript
            .condition(userCondition)
            .orderBy((script) => script.name.asc)
            .array;

        if (!guildId.isNull)
        {
            auto currentGuildId = cast(long) guildId.get.value;
            Condition delegate(ConditionBuilder!SavedScript) @safe guildCondition;
            guildCondition = (ConditionBuilder!SavedScript script) @safe => Condition.and(
                script.scopeType.equals(scopeName(ScriptScope.server)),
                script.guildId.equals(currentGuildId)
            );

            auto guildScripts = _db.select!SavedScript
                .condition(guildCondition)
                .orderBy((script) => script.name.asc)
                .array;
            scripts ~= guildScripts;
        }

        sort!((left, right) {
            if (left.scopeType == right.scopeType)
                return left.name < right.name;
            return left.scopeType < right.scopeType;
        })(scripts);

        return Result!(SavedScript[], string).ok(scripts);
    }

    Result!(SavedScript, string) findRunnable(
        string rawName,
        Snowflake requesterUserId,
        Nullable!Snowflake guildId
    )
    {
        auto name = normalizeName(rawName);
        if (name.isErr)
            return Result!(SavedScript, string).err(name.error);

        auto userScript = findUserScript(name.value, requesterUserId);
        if (!userScript.isNull)
            return Result!(SavedScript, string).ok(userScript.get);

        if (!guildId.isNull)
        {
            auto guildScript = findGuildScript(name.value, cast(long) guildId.get.value);
            if (!guildScript.isNull)
                return Result!(SavedScript, string).ok(guildScript.get);
        }

        return Result!(SavedScript, string).err("No accessible script named `" ~ name.value ~ "` was found.");
    }

    private Result!(SavedScript, string) owned(
        ScriptScope scriptScope,
        string name,
        Snowflake ownerUserId,
        Nullable!Snowflake guildId
    )
    {
        auto dbGuildId = normalizeGuild(scriptScope, guildId);
        if (dbGuildId.isErr)
            return Result!(SavedScript, string).err(dbGuildId.error);

        auto found = scriptScope == ScriptScope.user
            ? findUserScript(name, ownerUserId)
            : findOwnedGuildScript(name, ownerUserId, dbGuildId.value.get);

        if (found.isNull)
        {
            return Result!(SavedScript, string).err(
                "You do not own a " ~ scopeName(scriptScope) ~ " script named `" ~ name ~ "`."
            );
        }

        return Result!(SavedScript, string).ok(found.get);
    }

    private bool existsForCreate(
        ScriptScope scriptScope,
        string name,
        Snowflake ownerUserId,
        StdTypecons.Nullable!long guildId
    )
    {
        return scriptScope == ScriptScope.user
            ? !findUserScript(name, ownerUserId).isNull
            : !findGuildScript(name, guildId.get).isNull;
    }

    private StdTypecons.Nullable!SavedScript findUserScript(string name, Snowflake ownerUserId)
    {
        auto ownerId = cast(long) ownerUserId.value;
        Condition delegate(ConditionBuilder!SavedScript) @safe condition;
        condition = (ConditionBuilder!SavedScript script) @safe => Condition.and(
            script.name.equals(name),
            script.scopeType.equals(scopeName(ScriptScope.user)),
            script.ownerUserId.equals(ownerId)
        );

        return _db.select!SavedScript
            .condition(condition)
            .findOptional;
    }

    private StdTypecons.Nullable!SavedScript findGuildScript(string name, long guildId)
    {
        Condition delegate(ConditionBuilder!SavedScript) @safe condition;
        condition = (ConditionBuilder!SavedScript script) @safe => Condition.and(
            script.name.equals(name),
            script.scopeType.equals(scopeName(ScriptScope.server)),
            script.guildId.equals(guildId)
        );

        return _db.select!SavedScript
            .condition(condition)
            .findOptional;
    }

    private StdTypecons.Nullable!SavedScript findOwnedGuildScript(
        string name,
        Snowflake ownerUserId,
        long guildId
    )
    {
        auto ownerId = cast(long) ownerUserId.value;
        Condition delegate(ConditionBuilder!SavedScript) @safe condition;
        condition = (ConditionBuilder!SavedScript script) @safe => Condition.and(
            script.name.equals(name),
            script.scopeType.equals(scopeName(ScriptScope.server)),
            script.ownerUserId.equals(ownerId),
            script.guildId.equals(guildId)
        );

        return _db.select!SavedScript
            .condition(condition)
            .findOptional;
    }
}

private Result!(ScriptScope, string) parseScope(string rawScope)
{
    auto normalized = asciiLower(rawScope.strip);
    if (normalized.length == 0 || normalized == "user")
        return Result!(ScriptScope, string).ok(ScriptScope.user);
    if (normalized == "server" || normalized == "guild")
        return Result!(ScriptScope, string).ok(ScriptScope.server);

    return Result!(ScriptScope, string).err("Scope must be `user` or `server`.");
}

private Result!(string, string) normalizeName(string rawName)
{
    auto name = asciiLower(rawName.strip);
    if (name.length == 0)
        return Result!(string, string).err("Script names cannot be empty.");
    if (name.length > MaxScriptNameLength)
        return Result!(string, string).err("Script names must be at most 32 characters.");

    foreach (ch; name)
    {
        if (isAlphaNum(ch) || ch == '-' || ch == '_')
            continue;
        return Result!(string, string).err(
            "Script names may only use lowercase letters, numbers, `-`, and `_`."
        );
    }

    return Result!(string, string).ok(name);
}

private Result!(string, string) normalizeSource(string rawSource)
{
    auto source = rawSource.strip;
    if (source.length == 0)
        return Result!(string, string).err("Script source cannot be empty.");
    if (source.length > MaxScriptSourceLength)
        return Result!(string, string).err("Script source must stay under 6000 characters.");

    return Result!(string, string).ok(source);
}

private Result!(StdTypecons.Nullable!long, string) normalizeGuild(
    ScriptScope scriptScope,
    Nullable!Snowflake guildId
)
{
    if (scriptScope == ScriptScope.user)
        return Result!(StdTypecons.Nullable!long, string).ok(StdTypecons.Nullable!long.init);

    if (guildId.isNull)
        return Result!(StdTypecons.Nullable!long, string)
                  .err("Server-scoped scripts can only be used inside a server.");

    return Result!(StdTypecons.Nullable!long, string).ok(
        StdTypecons.Nullable!long(cast(long) guildId.get.value)
    );
}

string scopeName(ScriptScope scriptScope) @safe
{
    return scriptScope == ScriptScope.server ? "server" : "user";
}

private string asciiLower(string input) @safe
{
    auto lowered = input.dup;
    foreach (index, ch; lowered)
        lowered[index] = toLower(ch);
    return lowered.idup;
}
