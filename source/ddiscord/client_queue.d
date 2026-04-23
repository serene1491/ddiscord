/**
 * ddiscord — client dispatch queue helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_queue;

/// Result of attempting to enqueue a dispatch item.
struct DispatchQueuePushOutcome
{
    bool accepted;
    bool droppedIncoming;
    bool droppedOldest;
    size_t depth;
    ulong droppedTotal;
}

/// Returns the number of queued items available for consumption.
size_t queueDepth(T)(T[] queue, size_t head) pure @safe
{
    if (head >= queue.length)
        return 0;
    return queue.length - head;
}

/// Compacts queue storage once enough consumed items accumulate.
void compactQueue(T)(ref T[] queue, ref size_t head)
{
    if (head == 0)
        return;

    if (head >= queue.length)
    {
        queue.length = 0;
        head = 0;
        return;
    }

    if (head >= 64 && head * 2 >= queue.length)
    {
        queue = queue[head .. $].dup;
        head = 0;
    }
}

/// Pushes an item while honoring a queue depth budget.
DispatchQueuePushOutcome pushBounded(T)(
    ref T[] queue,
    ref size_t head,
    T item,
    size_t maxDepth,
    bool dropOldestOnOverflow,
    ref ulong droppedTotal
)
{
    DispatchQueuePushOutcome outcome;

    // Keep memory pressure under control before computing depth.
    compactQueue(queue, head);

    auto depth = queueDepth(queue, head);
    if (maxDepth != 0 && depth >= maxDepth)
    {
        droppedTotal++;
        outcome.droppedTotal = droppedTotal;

        if (dropOldestOnOverflow && depth != 0)
        {
            head++;
            compactQueue(queue, head);
            outcome.droppedOldest = true;
        }
        else
        {
            outcome.droppedIncoming = true;
            outcome.accepted = false;
            outcome.depth = depth;
            return outcome;
        }
    }

    queue ~= item;
    outcome.accepted = true;
    outcome.depth = queueDepth(queue, head);
    outcome.droppedTotal = droppedTotal;
    return outcome;
}

unittest
{
    int[] queue;
    size_t head;
    ulong dropped;

    foreach (value; 0 .. 3)
    {
        auto pushed = pushBounded(queue, head, value, 2, false, dropped);
        if (value < 2)
            assert(pushed.accepted);
        else
            assert(pushed.droppedIncoming);
    }

    assert(queueDepth(queue, head) == 2);
    assert(dropped == 1);
}

unittest
{
    int[] queue;
    size_t head;
    ulong dropped;

    auto _ = pushBounded(queue, head, 1, 2, true, dropped);
    _ = pushBounded(queue, head, 2, 2, true, dropped);
    auto pushed = pushBounded(queue, head, 3, 2, true, dropped);

    assert(pushed.accepted);
    assert(pushed.droppedOldest);
    assert(queueDepth(queue, head) == 2);
    assert(dropped == 1);
}

