module models;

import dorm.design;
import std.datetime : SysTime;
import StdTypecons = std.typecons;

mixin RegisterModels;

class SavedScript : Model
{
    @Id long id;
    @maxLength(32) string name;
    @maxLength(16) string scopeType;
    long ownerUserId;
    StdTypecons.Nullable!long guildId;
    @maxLength(6000) string source;
    @autoCreateTime SysTime createdAt;
    @autoCreateTime @autoUpdateTime SysTime updatedAt;
}
