-- Pure effect-event batcher. The server pushes cosmetic events as they happen and flushes at most one packet per interval.
--   * Impact events ("h") are lossy: beyond `hitsPerBatch` they are dropped (a drop costs only a spark).
--   * Important events (destruction "x", stage "s", notices "n") are never dropped, but are capped per packet; overflow rolls
--     into the next packet in order.
-- No Roblox types and no clock of its own: the caller supplies `now`.

local Batch = {}

function Batch.New(interval: number, hitsPerBatch: number, maxEvents: number)
    return {
        interval = interval,
        hitsPerBatch = hitsPerBatch,
        maxEvents = maxEvents,
        hits = {},
        important = {},
        lastFlush = -math.huge,
        dropped = 0,
        sent = 0,
        packets = 0,
    }
end

-- Lossy impact event. Returns whether it was kept.
function Batch.PushHit(b, event): boolean
    if #b.hits >= b.hitsPerBatch then
        b.dropped += 1
        return false
    end
    table.insert(b.hits, event)
    return true
end

function Batch.Push(b, event)
    table.insert(b.important, event)
end

function Batch.Pending(b): number
    return #b.hits + #b.important
end

-- Returns an array of events (never longer than maxEvents) or nil when there is nothing to send or it is too early.
function Batch.Flush(b, now: number)
    if now - b.lastFlush < b.interval then
        return nil
    end
    if #b.hits == 0 and #b.important == 0 then
        return nil
    end
    b.lastFlush = now
    local out = {}
    -- Important events first, preserving order; whatever does not fit stays queued for the next packet.
    local take = math.min(#b.important, b.maxEvents)
    for i = 1, take do
        out[i] = b.important[i]
    end
    if take > 0 then
        local rest = {}
        for i = take + 1, #b.important do
            table.insert(rest, b.important[i])
        end
        b.important = rest
    end
    for i = 1, #b.hits do
        if #out >= b.maxEvents then
            b.dropped += #b.hits - i + 1
            break
        end
        table.insert(out, b.hits[i])
    end
    b.hits = {}
    b.sent += #out
    b.packets += 1
    return out
end

function Batch.Clear(b)
    b.hits, b.important = {}, {}
end

return Batch
