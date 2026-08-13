local QBCore = exports['qb-core']:GetCoreObject()
local Sessions = {}
local Starting = {}
local RateLimits = {}
local IssuedWorkVehiclePlates = {}

local Events = LS_DELIVERY.Events
local Status = LS_DELIVERY.SessionStatus
local Repository = LS_DELIVERY.Repository
local VehicleKeysResource = 'qb-vehiclekeys'

assert(type(Repository) == 'table', 'Delivery repository was not loaded before server/main.lua')

local function debugLog(message, ...)
    if not Config.Debug then
        return
    end

    print(('[ls-job-system] ' .. message):format(...))
end

local function notify(playerSource, message, notificationType)
    QBCore.Functions.Notify(playerSource, message, notificationType or 'primary', 5000)
end

local function isInteger(value)
    return type(value) == 'number' and value % 1 == 0
end

local function hasCoordinates(coords)
    return coords and type(coords.x) == 'number' and type(coords.y) == 'number' and
        type(coords.z) == 'number'
end

local function validateConfig()
    assert(type(Config.DeliveryLocations) == 'table', 'Config.DeliveryLocations must be a table')
    assert(#Config.DeliveryLocations >= Config.DeliveriesPerJob.max,
        'Config.DeliveryLocations must contain at least DeliveriesPerJob.max entries')
    assert(isInteger(Config.DeliveriesPerJob.min) and isInteger(Config.DeliveriesPerJob.max) and
        Config.DeliveriesPerJob.min > 0 and Config.DeliveriesPerJob.min <= Config.DeliveriesPerJob.max,
        'Invalid Config.DeliveriesPerJob range')
    assert(isInteger(Config.Rewards.perDelivery.min) and isInteger(Config.Rewards.perDelivery.max) and
        Config.Rewards.perDelivery.min >= 0 and
        Config.Rewards.perDelivery.min <= Config.Rewards.perDelivery.max,
        'Invalid Config.Rewards.perDelivery range')
    assert(type(Config.Rewards.account) == 'string' and Config.Rewards.account ~= '',
        'Config.Rewards.account is required')
    assert(type(Config.Interaction.requestTimeoutMs) == 'number' and Config.Interaction.requestTimeoutMs > 0,
        'Config.Interaction.requestTimeoutMs must be greater than 0')
    assert(hasCoordinates(Config.JobNPC.coords), 'Config.JobNPC.coords requires numeric x, y, and z values')
    assert(type(Config.JobNPC.coords.w) == 'number', 'Config.JobNPC.coords requires a numeric heading')
    assert(type(Config.JobNPC.interactionDistance) == 'number' and Config.JobNPC.interactionDistance > 0,
        'Config.JobNPC.interactionDistance must be greater than 0')
    assert(hasCoordinates(Config.ReturnPoint.coords),
        'Config.ReturnPoint.coords requires numeric x, y, and z values')
    assert(type(Config.ReturnPoint.validationDistance) == 'number' and
        Config.ReturnPoint.validationDistance > 0,
        'Config.ReturnPoint.validationDistance must be greater than 0')
    assert(isInteger(Config.Rewards.completionBonus) and Config.Rewards.completionBonus >= 0,
        'Config.Rewards.completionBonus must be a non-negative integer')
    assert(type(Config.Validation.deliveryDistance) == 'number' and Config.Validation.deliveryDistance > 0,
        'Config.Validation.deliveryDistance must be greater than 0')
    assert(type(Config.Validation.startDistance) == 'number' and Config.Validation.startDistance > 0,
        'Config.Validation.startDistance must be greater than 0')
    assert(type(Config.Validation.eventCooldownMs) == 'number' and Config.Validation.eventCooldownMs >= 0,
        'Config.Validation.eventCooldownMs must not be negative')
    assert(type(Config.Validation.startCooldownMs) == 'number' and Config.Validation.startCooldownMs >= 0,
        'Config.Validation.startCooldownMs must not be negative')
    assert(type(Config.Validation.stateSyncCooldownMs) == 'number' and
        Config.Validation.stateSyncCooldownMs >= 0,
        'Config.Validation.stateSyncCooldownMs must not be negative')

    local ids = {}
    for index, location in ipairs(Config.DeliveryLocations) do
        assert(type(location.id) == 'string' and location.id ~= '',
            ('Delivery location %d requires a unique id'):format(index))
        assert(not ids[location.id], ('Duplicate delivery location id: %s'):format(location.id))
        assert(hasCoordinates(location.coords),
            ('Delivery location %s requires numeric x, y, and z coordinates'):format(location.id))
        ids[location.id] = true
    end

    if Config.WorkVehicle.enabled then
        assert(type(Config.WorkVehicle.model) == 'string' and Config.WorkVehicle.model ~= '',
            'Config.WorkVehicle.model is required when vehicle spawning is enabled')
        assert(type(Config.WorkVehicle.type) == 'string' and Config.WorkVehicle.type ~= '',
            'Config.WorkVehicle.type is required when vehicle spawning is enabled')
        assert(hasCoordinates(Config.WorkVehicle.spawn),
            'Config.WorkVehicle.spawn requires numeric x, y, and z values')
        assert(type(Config.WorkVehicle.spawn.w) == 'number',
            'Config.WorkVehicle.spawn requires a numeric heading')
        assert(type(Config.WorkVehicle.spawnClearance) == 'number' and Config.WorkVehicle.spawnClearance > 0,
            'Config.WorkVehicle.spawnClearance must be greater than 0')
        assert(type(Config.WorkVehicle.platePrefix) == 'string' and
            Config.WorkVehicle.platePrefix:match('^[A-Z0-9]+$'),
            'Config.WorkVehicle.platePrefix must contain uppercase letters or numbers')
        assert(isInteger(Config.WorkVehicle.plateDigits) and
            Config.WorkVehicle.plateDigits >= 3 and Config.WorkVehicle.plateDigits <= 6,
            'Config.WorkVehicle.plateDigits must be between 3 and 6')
        assert(#Config.WorkVehicle.platePrefix + Config.WorkVehicle.plateDigits <= 8,
            'Work vehicle plates must contain at most 8 characters')
        assert(isInteger(Config.WorkVehicle.plateGenerationAttempts) and
            Config.WorkVehicle.plateGenerationAttempts >= 1,
            'Config.WorkVehicle.plateGenerationAttempts must be at least 1')
        assert(type(Config.WorkVehicle.networkEntityTimeoutMs) == 'number' and
            Config.WorkVehicle.networkEntityTimeoutMs > 0,
            'Config.WorkVehicle.networkEntityTimeoutMs must be greater than 0')
    end
end

local function squaredDistance(first, second)
    local deltaX = first.x - second.x
    local deltaY = first.y - second.y
    local deltaZ = first.z - second.z
    return deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
end

local function normalizePlate(plate)
    if type(plate) ~= 'string' then
        return nil
    end

    return plate:match('^%s*(.-)%s*$'):upper()
end

local function isStoredWorkVehicle(session)
    if not session or not session.vehicle or not session.vehicleNetId or
        not session.vehicleModel or not DoesEntityExist(session.vehicle) then
        return false
    end

    local netIdCallSucceeded, currentNetId = pcall(NetworkGetNetworkIdFromEntity, session.vehicle)
    if not netIdCallSucceeded or currentNetId ~= session.vehicleNetId then
        return false
    end

    local modelCallSucceeded, currentModel = pcall(GetEntityModel, session.vehicle)
    if not modelCallSucceeded or currentModel ~= session.vehicleModel then
        return false
    end

    if session.vehiclePlate then
        local plateCallSucceeded, currentPlate = pcall(GetVehicleNumberPlateText, session.vehicle)
        if not plateCallSucceeded then
            print(('[ls-job-system] Could not inspect the stored work vehicle plate for entity %d')
                :format(session.vehicle))
        elseif normalizePlate(currentPlate) ~= normalizePlate(session.vehiclePlate) then
            print(('[ls-job-system] Work vehicle plate mismatch for entity %d (expected %s, found %s)')
                :format(session.vehicle, session.vehiclePlate, tostring(currentPlate)))
        end
    end

    return true
end

local function getPlayerPosition(playerSource)
    if type(playerSource) ~= 'number' or playerSource <= 0 then
        return nil
    end

    local pedCallSucceeded, ped = pcall(GetPlayerPed, playerSource)
    if not pedCallSucceeded or not ped or ped <= 0 or not DoesEntityExist(ped) then
        return nil
    end

    local coordsCallSucceeded, coords = pcall(GetEntityCoords, ped)
    if not coordsCallSucceeded or not hasCoordinates(coords) then
        return nil
    end

    return coords
end

local function isPlayerNearCoordinates(playerSource, target, maximumDistance)
    if not hasCoordinates(target) or type(maximumDistance) ~= 'number' or maximumDistance <= 0 then
        return false
    end

    local playerCoords = getPlayerPosition(playerSource)
    if not playerCoords then
        return false
    end

    return squaredDistance(playerCoords, target) <= maximumDistance * maximumDistance
end

local function isRateLimited(playerSource, action, cooldownMs)
    local now = GetGameTimer()
    RateLimits[playerSource] = RateLimits[playerSource] or {}

    local lastRequest = RateLimits[playerSource][action]
    if lastRequest and now - lastRequest < cooldownMs then
        return true
    end

    RateLimits[playerSource][action] = now
    return false
end

local function serializeLocation(location)
    return {
        id = location.id,
        label = location.label,
        coords = {
            x = location.coords.x,
            y = location.coords.y,
            z = location.coords.z
        }
    }
end

local function serializeSession(session)
    local currentDelivery = session.deliveries[session.currentDelivery]
    local vehicleNetId

    if isStoredWorkVehicle(session) then
        vehicleNetId = session.vehicleNetId
    end

    return {
        status = session.status,
        completedDeliveries = session.completedDeliveries,
        totalDeliveries = #session.deliveries,
        currentDelivery = currentDelivery and serializeLocation(currentDelivery) or nil,
        returnPoint = {
            x = Config.ReturnPoint.coords.x,
            y = Config.ReturnPoint.coords.y,
            z = Config.ReturnPoint.coords.z
        },
        vehicleNetId = vehicleNetId,
        vehiclePlate = session.vehiclePlate
    }
end

local function chooseDeliveries()
    local indexes = {}
    for index = 1, #Config.DeliveryLocations do
        indexes[index] = index
    end

    for index = #indexes, 2, -1 do
        local swapIndex = math.random(index)
        indexes[index], indexes[swapIndex] = indexes[swapIndex], indexes[index]
    end

    local deliveryCount = math.random(Config.DeliveriesPerJob.min, Config.DeliveriesPerJob.max)
    local selected = {}
    for index = 1, deliveryCount do
        selected[index] = Config.DeliveryLocations[indexes[index]]
    end

    return selected
end

local function isVehicleSpawnClear()
    local vehicles = GetAllVehicles()
    local spawnCoords = Config.WorkVehicle.spawn
    local clearanceSquared = Config.WorkVehicle.spawnClearance * Config.WorkVehicle.spawnClearance

    for index = 1, #vehicles do
        local vehicle = vehicles[index]
        if DoesEntityExist(vehicle) then
            local vehicleCoords = GetEntityCoords(vehicle)
            if squaredDistance(vehicleCoords, spawnCoords) < clearanceSquared then
                return false
            end
        end
    end

    return true
end

local function isWorkVehiclePlateInUse(plate)
    if IssuedWorkVehiclePlates[plate] then
        return true
    end

    for _, session in pairs(Sessions) do
        if normalizePlate(session.vehiclePlate) == plate then
            return true
        end
    end

    for _, startToken in pairs(Starting) do
        if normalizePlate(startToken.vehiclePlate) == plate then
            return true
        end
    end

    local vehicles = GetAllVehicles()
    for index = 1, #vehicles do
        local vehicle = vehicles[index]
        if DoesEntityExist(vehicle) then
            local plateCallSucceeded, existingPlate = pcall(GetVehicleNumberPlateText, vehicle)
            if plateCallSucceeded and normalizePlate(existingPlate) == plate then
                return true
            end
        end
    end

    return false
end

local function generateWorkVehiclePlate()
    local prefix = Config.WorkVehicle.platePrefix
    local digits = Config.WorkVehicle.plateDigits
    local maximumSuffix = (10 ^ digits) - 1
    local suffixFormat = ('%%0%dd'):format(digits)

    for _ = 1, Config.WorkVehicle.plateGenerationAttempts do
        local suffix = suffixFormat:format(math.random(0, maximumSuffix))
        local plate = prefix .. suffix

        if not isWorkVehiclePlateInUse(plate) then
            IssuedWorkVehiclePlates[plate] = true
            return plate
        end
    end

    return nil
end

local function deleteWorkVehicle(vehicle, context)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return true
    end

    local deleteSucceeded, deleteError = pcall(DeleteEntity, vehicle)
    if not deleteSucceeded then
        print(('[ls-job-system] Failed to delete work vehicle (%s): %s')
            :format(context or 'unknown', tostring(deleteError)))
        return false
    end

    if DoesEntityExist(vehicle) then
        print(('[ls-job-system] Work vehicle still exists after cleanup (%s), entity %d')
            :format(context or 'unknown', vehicle))
        return false
    end

    return true
end

local function createWorkVehicle(playerSource, plate)
    if not Config.WorkVehicle.enabled then
        return nil, nil, nil, nil
    end

    if not isVehicleSpawnClear() then
        return nil, nil, nil, 'El punto de salida del vehículo está ocupado.'
    end

    local createSucceeded, vehicle = pcall(
        QBCore.Functions.CreateVehicle,
        playerSource,
        Config.WorkVehicle.model,
        Config.WorkVehicle.type,
        Config.WorkVehicle.spawn,
        false
    )

    if not createSucceeded then
        print(('[ls-job-system] QBCore vehicle creation failed for source %d: %s')
            :format(playerSource, tostring(vehicle)))
        return nil, nil, nil, 'No se pudo crear el vehículo de trabajo.'
    end

    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil, nil, nil, 'No se pudo crear el vehículo de trabajo.'
    end

    local expectedModel = joaat(Config.WorkVehicle.model)
    local modelCallSucceeded, currentModel = pcall(GetEntityModel, vehicle)
    if not modelCallSucceeded or currentModel ~= expectedModel then
        print(('[ls-job-system] Work vehicle model mismatch for source %d (expected %s, found %s)')
            :format(playerSource, tostring(expectedModel), tostring(currentModel)))
        deleteWorkVehicle(vehicle, 'model mismatch')
        return nil, nil, nil, 'El vehículo creado no coincide con el modelo configurado.'
    end

    local configureSucceeded, configureError = pcall(function()
        SetVehicleNumberPlateText(vehicle, plate)
        SetVehicleDoorsLocked(vehicle, 1)
    end)

    if not configureSucceeded then
        print(('[ls-job-system] Failed to configure work vehicle for source %d: %s')
            :format(playerSource, tostring(configureError)))
        deleteWorkVehicle(vehicle, 'configuration failure')
        return nil, nil, nil, 'No se pudo configurar el vehículo de trabajo.'
    end

    local netIdCallSucceeded, vehicleNetId = pcall(NetworkGetNetworkIdFromEntity, vehicle)
    if not netIdCallSucceeded or not vehicleNetId or vehicleNetId <= 0 then
        print(('[ls-job-system] Work vehicle has no valid network id for source %d'):format(playerSource))
        deleteWorkVehicle(vehicle, 'invalid network id')
        return nil, nil, nil, 'No se pudo sincronizar el vehículo de trabajo.'
    end

    return vehicle, vehicleNetId, expectedModel, nil
end

local function giveWorkVehicleKeys(playerSource, plate)
    local giveSucceeded, hasKeysOrError = pcall(function()
        exports[VehicleKeysResource]:GiveKeys(playerSource, plate)
        return exports[VehicleKeysResource]:HasKeys(playerSource, plate)
    end)

    if not giveSucceeded then
        print(('[ls-job-system] Failed to give work vehicle keys to source %d: %s')
            :format(playerSource, tostring(hasKeysOrError)))
        return false
    end

    if hasKeysOrError ~= true then
        print(('[ls-job-system] qb-vehiclekeys did not confirm keys for source %d, plate %s')
            :format(playerSource, plate))
        return false
    end

    return true
end

local function revokeWorkVehicleKeys(playerSource, session, persistMetadata)
    if not session or not session.vehiclePlate or not session.keysGranted then
        return true
    end

    local player = QBCore.Functions.GetPlayer(playerSource)
    if not player or not player.PlayerData or player.PlayerData.citizenid ~= session.citizenId then
        print(('[ls-job-system] Could not revoke keys for plate %s: session player is unavailable')
            :format(session.vehiclePlate))
        return false
    end

    local removeSucceeded, removeError = pcall(function()
        exports[VehicleKeysResource]:RemoveKeys(playerSource, session.vehiclePlate)
    end)

    if not removeSucceeded then
        print(('[ls-job-system] Failed to revoke keys from source %d, plate %s: %s')
            :format(playerSource, session.vehiclePlate, tostring(removeError)))
        return false
    end

    local verifySucceeded, stillHasKeys = pcall(function()
        return exports[VehicleKeysResource]:HasKeys(playerSource, session.vehiclePlate)
    end)

    if not verifySucceeded or stillHasKeys then
        print(('[ls-job-system] Could not verify key revocation for source %d, plate %s')
            :format(playerSource, session.vehiclePlate))
        return false
    end

    session.keysGranted = false

    if persistMetadata then
        local saveSucceeded, saveError = pcall(player.Functions.Save)
        if not saveSucceeded then
            print(('[ls-job-system] Keys were revoked but player metadata save failed for source %d: %s')
                :format(playerSource, tostring(saveError)))
            return false
        end
    end

    return true
end

local function cleanupSessionAssets(playerSource, session, context, persistKeyRemoval)
    local keysRevoked = revokeWorkVehicleKeys(playerSource, session, persistKeyRemoval)
    local vehicleDeleted = true

    if session and session.vehicle and DoesEntityExist(session.vehicle) then
        if isStoredWorkVehicle(session) then
            vehicleDeleted = deleteWorkVehicle(session.vehicle, context)
        else
            vehicleDeleted = false
            print(('[ls-job-system] Refused to delete a vehicle that no longer matches its session (%s)')
                :format(context or 'unknown'))
        end
    end

    return keysRevoked, vehicleDeleted
end

local function clearSession(playerSource, context, persistKeyRemoval)
    local session = Sessions[playerSource]
    local startToken = Starting[playerSource]
    Sessions[playerSource] = nil
    Starting[playerSource] = nil

    local assets = session or startToken
    if not assets then
        return true, true
    end

    return cleanupSessionAssets(playerSource, assets, context, persistKeyRemoval)
end

local function reject(playerSource, message)
    TriggerClientEvent(Events.RequestRejected, playerSource, message)
end

local function getValidatedSessionPlayer(playerSource, session)
    local player = QBCore.Functions.GetPlayer(playerSource)
    if not player or not player.PlayerData or player.PlayerData.citizenid ~= session.citizenId then
        return nil
    end

    return player
end

RegisterNetEvent(Events.RequestStart, function()
    local playerSource = source

    if isRateLimited(playerSource, 'start', Config.Validation.startCooldownMs) then
        reject(playerSource, 'Esperá un momento antes de volver a intentarlo.')
        return
    end

    if Sessions[playerSource] or Starting[playerSource] then
        reject(playerSource, 'Ya tenés un turno de reparto activo.')
        return
    end

    local player = QBCore.Functions.GetPlayer(playerSource)
    if not player or not player.PlayerData or not player.PlayerData.citizenid then
        reject(playerSource, 'No se pudo cargar tu personaje.')
        return
    end

    local startToken = {
        citizenId = player.PlayerData.citizenid
    }
    Starting[playerSource] = startToken

    if not isPlayerNearCoordinates(playerSource, Config.JobNPC.coords, Config.Validation.startDistance) then
        if Starting[playerSource] == startToken then
            Starting[playerSource] = nil
        end
        reject(playerSource, 'Tenés que estar junto al encargado para iniciar el turno.')
        return
    end

    local plate
    if Config.WorkVehicle.enabled then
        plate = generateWorkVehiclePlate()
    end

    if Config.WorkVehicle.enabled and not plate then
        if Starting[playerSource] == startToken then
            Starting[playerSource] = nil
        end
        print(('[ls-job-system] Failed to generate a unique work vehicle plate after %d attempts')
            :format(Config.WorkVehicle.plateGenerationAttempts))
        reject(playerSource, 'No se pudo reservar una matrícula única para el vehículo de trabajo.')
        return
    end

    startToken.vehiclePlate = plate

    local vehicle, vehicleNetId, vehicleModel, vehicleError = createWorkVehicle(playerSource, plate)
    if Config.WorkVehicle.enabled and not vehicle then
        if Starting[playerSource] == startToken then
            Starting[playerSource] = nil
        end
        reject(playerSource, vehicleError or 'No se pudo preparar el vehículo de trabajo.')
        return
    end

    startToken.vehicle = vehicle
    startToken.vehicleNetId = vehicleNetId
    startToken.vehicleModel = vehicleModel

    local currentPlayer = QBCore.Functions.GetPlayer(playerSource)
    local startStillOwned = Starting[playerSource] == startToken
    local sameCharacter = currentPlayer and currentPlayer.PlayerData and
        currentPlayer.PlayerData.citizenid == startToken.citizenId

    if not startStillOwned or not sameCharacter then
        deleteWorkVehicle(vehicle, 'stale start attempt')
        if startStillOwned then
            Starting[playerSource] = nil
        end
        return
    end

    local keysGranted = false
    if Config.WorkVehicle.enabled then
        keysGranted = giveWorkVehicleKeys(playerSource, plate)
        if not keysGranted then
            local temporarySession = {
                citizenId = startToken.citizenId,
                vehicle = vehicle,
                vehicleNetId = vehicleNetId,
                vehicleModel = vehicleModel,
                vehiclePlate = plate,
                keysGranted = true
            }
            cleanupSessionAssets(playerSource, temporarySession, 'key grant failure', true)
            if Starting[playerSource] == startToken then
                Starting[playerSource] = nil
            end
            reject(playerSource, 'No se pudieron asignar las llaves del vehículo de trabajo.')
            return
        end
    end
    startToken.keysGranted = keysGranted

    local session = {
        citizenId = startToken.citizenId,
        deliveries = chooseDeliveries(),
        currentDelivery = 1,
        completedDeliveries = 0,
        status = Status.Delivering,
        processing = false,
        vehicle = vehicle,
        vehicleNetId = vehicleNetId,
        vehicleModel = vehicleModel,
        vehiclePlate = plate,
        keysGranted = keysGranted
    }

    Sessions[playerSource] = session
    Starting[playerSource] = nil

    debugLog('Started session for source %d with %d deliveries', playerSource, #session.deliveries)
    TriggerClientEvent(Events.SyncSession, playerSource, serializeSession(session), true)
    notify(playerSource, ('Turno iniciado: %d entregas asignadas.'):format(#session.deliveries), 'success')
end)

RegisterNetEvent(Events.RequestState, function()
    local playerSource = source
    local session = Sessions[playerSource]
    if not session then
        return
    end

    if isRateLimited(playerSource, 'state', Config.Validation.stateSyncCooldownMs) then
        return
    end

    if not getValidatedSessionPlayer(playerSource, session) then
        clearSession(playerSource, 'state sync character mismatch', true)
        return
    end

    TriggerClientEvent(Events.SyncSession, playerSource, serializeSession(session), false)
end)

RegisterNetEvent(Events.CompleteDelivery, function()
    local playerSource = source
    local session = Sessions[playerSource]

    if not session then
        reject(playerSource, 'No tenés un turno activo.')
        return
    end

    if isRateLimited(playerSource, 'delivery', Config.Validation.eventCooldownMs) or session.processing then
        reject(playerSource, 'La entrega ya se está procesando.')
        return
    end

    if session.status ~= Status.Delivering then
        reject(playerSource, 'No hay una entrega pendiente para validar.')
        return
    end

    local player = getValidatedSessionPlayer(playerSource, session)
    if not player then
        clearSession(playerSource, 'delivery character mismatch', true)
        reject(playerSource, 'La sesión ya no corresponde al personaje activo.')
        return
    end

    local delivery = session.deliveries[session.currentDelivery]
    if not delivery then
        reject(playerSource, 'El estado de la ruta es inválido.')
        return
    end

    session.processing = true

    if not isPlayerNearCoordinates(playerSource, delivery.coords, Config.Validation.deliveryDistance) then
        session.processing = false
        reject(playerSource, 'No estás lo suficientemente cerca del destino asignado.')
        debugLog('Rejected out-of-range delivery from source %d', playerSource)
        return
    end

    session.completedDeliveries = session.completedDeliveries + 1
    session.currentDelivery = session.currentDelivery + 1
    session.processing = false

    local nextDelivery = session.deliveries[session.currentDelivery]
    if nextDelivery then
        TriggerClientEvent(Events.DeliveryAccepted, playerSource, {
            completedDeliveries = session.completedDeliveries,
            totalDeliveries = #session.deliveries,
            currentDelivery = serializeLocation(nextDelivery),
            status = Status.Delivering
        })
        notify(playerSource, 'Entrega confirmada. Se marcó el próximo destino.', 'success')
        return
    end

    session.status = Status.AwaitingReturn
    TriggerClientEvent(Events.DeliveryAccepted, playerSource, {
        completedDeliveries = session.completedDeliveries,
        totalDeliveries = #session.deliveries,
        currentDelivery = nil,
        status = Status.AwaitingReturn,
        returnPoint = {
            x = Config.ReturnPoint.coords.x,
            y = Config.ReturnPoint.coords.y,
            z = Config.ReturnPoint.coords.z
        }
    })
    notify(playerSource, 'Ruta completada. Volvé al depósito para cerrar el turno.', 'success')
end)

RegisterNetEvent(Events.FinishJob, function()
    local playerSource = source
    local session = Sessions[playerSource]

    if not session then
        reject(playerSource, 'No tenés un turno activo.')
        return
    end

    if isRateLimited(playerSource, 'finish', Config.Validation.eventCooldownMs) or session.processing then
        reject(playerSource, 'El cierre del turno ya se está procesando.')
        return
    end

    if session.status ~= Status.AwaitingReturn or session.completedDeliveries ~= #session.deliveries then
        reject(playerSource, 'Todavía quedan entregas pendientes.')
        return
    end

    local player = getValidatedSessionPlayer(playerSource, session)
    if not player then
        clearSession(playerSource, 'finish character mismatch', true)
        reject(playerSource, 'La sesión ya no corresponde al personaje activo.')
        return
    end

    if not isPlayerNearCoordinates(playerSource, Config.ReturnPoint.coords, Config.ReturnPoint.validationDistance) then
        reject(playerSource, 'Tenés que volver al depósito para cerrar el turno.')
        return
    end

    if Config.WorkVehicle.enabled and Config.WorkVehicle.requireAtReturn then
        if not isStoredWorkVehicle(session) then
            reject(playerSource, 'No se encontró el vehículo de trabajo asignado.')
            return
        end

        local coordsCallSucceeded, vehicleCoords = pcall(GetEntityCoords, session.vehicle)
        if not coordsCallSucceeded or not hasCoordinates(vehicleCoords) then
            reject(playerSource, 'No se pudo validar la posición del vehículo de trabajo.')
            return
        end

        if squaredDistance(vehicleCoords, Config.ReturnPoint.coords) >
            Config.ReturnPoint.validationDistance * Config.ReturnPoint.validationDistance then
            reject(playerSource, 'Dejá el vehículo de trabajo en el depósito.')
            return
        end
    end

    session.processing = true
    session.status = Status.Paying

    local reward = Config.Rewards.completionBonus
    for _ = 1, session.completedDeliveries do
        reward = reward + math.random(Config.Rewards.perDelivery.min, Config.Rewards.perDelivery.max)
    end

    reward = math.floor(reward)
    local paymentCallSucceeded, paymentAdded = pcall(
        player.Functions.AddMoney,
        Config.Rewards.account,
        reward,
        'ls-job-system:completed-delivery-route'
    )

    if not paymentCallSucceeded or not paymentAdded then
        session.processing = false
        session.status = Status.AwaitingReturn
        reject(playerSource, 'No se pudo acreditar el pago. El turno continúa abierto.')
        print(('[ls-job-system] Failed to add reward for source %d: %s')
            :format(playerSource, paymentCallSucceeded and 'AddMoney returned false' or tostring(paymentAdded)))
        return
    end

    local citizenId = session.citizenId
    local completedDeliveries = session.completedDeliveries

    -- Detach the paid session before any cleanup or persistence call can yield or fail.
    Sessions[playerSource] = nil
    Starting[playerSource] = nil

    local keysRevoked, vehicleDeleted = cleanupSessionAssets(
        playerSource,
        session,
        'completed job',
        true
    )

    if not keysRevoked or not vehicleDeleted then
        print(('[ls-job-system] Job paid for source %d but vehicle cleanup was incomplete (keys=%s, vehicle=%s)')
            :format(playerSource, tostring(keysRevoked), tostring(vehicleDeleted)))
    end

    local statsSaved, repositoryError = Repository.recordCompletedJob(
        citizenId,
        completedDeliveries,
        reward
    )

    if not statsSaved then
        print(('[ls-job-system] Reward paid but stats update failed for citizenid %s: %s')
            :format(citizenId, tostring(repositoryError)))
    end

    debugLog('Finished session for source %d: %d deliveries, $%d',
        playerSource, completedDeliveries, reward)

    local currentPlayer = QBCore.Functions.GetPlayer(playerSource)
    local sameCharacter = currentPlayer and currentPlayer.PlayerData and
        currentPlayer.PlayerData.citizenid == citizenId

    if not sameCharacter or Sessions[playerSource] or Starting[playerSource] then
        debugLog('Skipped completion event for stale or reused source %d', playerSource)
        return
    end

    TriggerClientEvent(Events.JobFinished, playerSource, {
        deliveriesCompleted = completedDeliveries,
        reward = reward,
        account = Config.Rewards.account,
        statsSaved = statsSaved
    })
end)

RegisterNetEvent(Events.CancelJob, function()
    local playerSource = source

    if isRateLimited(playerSource, 'cancel', Config.Validation.eventCooldownMs) then
        reject(playerSource, 'La cancelación ya se está procesando.')
        return
    end

    local session = Sessions[playerSource]
    if not session then
        reject(playerSource, 'No tenés un turno activo.')
        return
    end

    if not getValidatedSessionPlayer(playerSource, session) then
        clearSession(playerSource, 'cancel character mismatch', true)
        return
    end

    local keysRevoked, vehicleDeleted = clearSession(playerSource, 'cancelled job', true)
    if not keysRevoked or not vehicleDeleted then
        print(('[ls-job-system] Cancelled session cleanup was incomplete for source %d (keys=%s, vehicle=%s)')
            :format(playerSource, tostring(keysRevoked), tostring(vehicleDeleted)))
    end

    TriggerClientEvent(Events.JobCancelled, playerSource)
    debugLog('Cancelled session for source %d', playerSource)
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(playerSource)
    if Sessions[playerSource] or Starting[playerSource] then
        debugLog('Cleaning session for unloaded source %d', playerSource)
    end

    clearSession(playerSource, 'player unload', true)
    RateLimits[playerSource] = nil
end)

AddEventHandler('playerDropped', function()
    local playerSource = source
    if Sessions[playerSource] or Starting[playerSource] then
        debugLog('Cleaning session for disconnected source %d', playerSource)
    end

    clearSession(playerSource, 'player disconnect fallback', true)
    RateLimits[playerSource] = nil
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    local playerSources = {}
    local includedSources = {}
    for playerSource in pairs(Sessions) do
        playerSources[#playerSources + 1] = playerSource
        includedSources[playerSource] = true
    end

    for playerSource in pairs(Starting) do
        if not includedSources[playerSource] then
            playerSources[#playerSources + 1] = playerSource
        end
    end

    for index = 1, #playerSources do
        local playerSource = playerSources[index]
        local keysRevoked, vehicleDeleted = clearSession(playerSource, 'resource stop', true)
        if not keysRevoked or not vehicleDeleted then
            print(('[ls-job-system] Resource stop cleanup was incomplete for source %d (keys=%s, vehicle=%s)')
                :format(playerSource, tostring(keysRevoked), tostring(vehicleDeleted)))
        end
    end

    for playerSource in pairs(RateLimits) do
        RateLimits[playerSource] = nil
    end
end)

validateConfig()
