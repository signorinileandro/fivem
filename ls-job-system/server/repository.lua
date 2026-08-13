local Repository = {}
LS_DELIVERY.Repository = Repository

local UPSERT_STATS = [[
    INSERT INTO ls_delivery_stats (
        citizenid,
        jobs_completed,
        deliveries_completed,
        money_earned
    ) VALUES (?, 1, ?, ?)
    ON DUPLICATE KEY UPDATE
        jobs_completed = jobs_completed + 1,
        deliveries_completed = deliveries_completed + VALUES(deliveries_completed),
        money_earned = money_earned + VALUES(money_earned),
        updated_at = CURRENT_TIMESTAMP
]]

function Repository.recordCompletedJob(citizenId, deliveriesCompleted, moneyEarned)
    if type(citizenId) ~= 'string' or citizenId == '' then
        return false, 'invalid citizenid'
    end

    if type(deliveriesCompleted) ~= 'number' or deliveriesCompleted < 1 then
        return false, 'invalid delivery count'
    end

    if type(moneyEarned) ~= 'number' or moneyEarned < 0 then
        return false, 'invalid money amount'
    end

    local success, result = pcall(MySQL.update.await, UPSERT_STATS, {
        citizenId,
        math.floor(deliveriesCompleted),
        math.floor(moneyEarned)
    })

    if not success then
        return false, result
    end

    if type(result) ~= 'number' or result < 1 then
        return false, ('unexpected affected row count: %s'):format(tostring(result))
    end

    return true, result
end
