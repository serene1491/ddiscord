/**
 * ddiscord — internal client runtime support types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_support.runtime_types;

import core.thread : Thread;
import ddiscord.gateway.client : GatewayClient;
import ddiscord.models.channel : Channel;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.message : Message;

package(ddiscord) enum GatewayReadyWatchdogLabel = "gateway-ready-watchdog";
package(ddiscord) enum GatewayAutoReshardWatchdogLabel = "gateway-auto-reshard-watchdog";

package(ddiscord) struct ShardRuntime
{
    uint shardId;
    GatewayClient gateway;
    Thread thread;
}

package(ddiscord) struct DispatchItem
{
    enum Kind
    {
        Message,
        Interaction,
    }

    Kind kind;
    Message message;
    Interaction interaction;
    Channel channel;
    ulong permissions;
}
