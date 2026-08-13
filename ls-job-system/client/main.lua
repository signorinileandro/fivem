local QBCore = exports['qb-core']:GetCoreObject()
local Events = LS_DELIVERY.Events
local Status = LS_DELIVERY.SessionStatus

local dispatcherPed
local routeBlip
local dispatcherTargetRegistered = false
local dispatcherTargetName = ('%s-dispatcher'):format(GetCurrentResourceName())

local Job = {
    starting = false,
    active = false,
    status = nil,
    currentDelivery = nil,
    completedDeliveries = 0,
    totalDeliveries = 0,
    returnPoint = nil,
    vehicleNetId = nil,
    delivering = false
}

local function debugLog(message, ...)
    if not Config.Debug then
        return
    end

    print(('[ls-job-system] ' .. message):format(...))
end

local function removeRouteBlip()
    if routeBlip and DoesBlipExist(routeBlip) then
        RemoveBlip(routeBlip)
    end
    routeBlip = nil
end

local function createRouteBlip(coords, blipConfig)
    removeRouteBlip()

    routeBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(routeBlip, blipConfig.sprite)
    SetBlipColour(routeBlip, blipConfig.color)
    SetBlipScale(routeBlip, blipConfig.scale)
    SetBlipRoute(routeBlip, true)
    SetBlipRouteColour(routeBlip, blipConfig.color)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(blipConfig.label)
    EndTextCommandSetBlipName(routeBlip)
end

local function updateRoute()
    if not Job.active then
        removeRouteBlip()
        return
    end

    if Job.status == Status.Delivering and Job.currentDelivery then
        createRouteBlip(Job.currentDelivery.coords, Config.Blips.delivery)
        return
    end

    if Job.status == Status.AwaitingReturn and Job.returnPoint then
        createRouteBlip(Job.returnPoint, Config.Blips.returnPoint)
        return
    end

    removeRouteBlip()
end

local function resetJobState()
    removeRouteBlip()
    Job.starting = false
    Job.active = false
    Job.status = nil
    Job.currentDelivery = nil
    Job.completedDeliveries = 0
    Job.totalDeliveries = 0
    Job.returnPoint = nil
    Job.vehicleNetId = nil
    Job.delivering = false
end

local function showHelpText(message)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function waitForNetworkEntity(netId, timeoutMs)
    if type(netId) ~= 'number' or netId <= 0 then
        return nil
    end

    local timeoutAt = GetGameTimer() + timeoutMs
    repeat
        if NetworkDoesNetworkIdExist(netId) then
            local entity = NetworkGetEntityFromNetworkId(netId)
            if entity and entity ~= 0 and DoesEntityExist(entity) then
                return entity
            end
        end

        Wait(50)
    until GetGameTimer() >= timeoutAt

    return nil
end

local function configureWorkVehicle(netId, plate)
    if not netId then
        return
    end

    CreateThread(function()
        local vehicle = waitForNetworkEntity(netId, Config.WorkVehicle.networkEntityTimeoutMs)
        if not vehicle then
            print(('[ls-job-system] Timed out waiting for work vehicle network entity %s')
                :format(tostring(netId)))
            if Job.active and Job.vehicleNetId == netId then
                QBCore.Functions.Notify(
                    'No se pudo sincronizar visualmente el vehículo. El turno sigue activo.',
                    'error',
                    6500
                )
            end
            return
        end

        if not Job.active or Job.vehicleNetId ~= netId then
            debugLog('Ignoring stale work vehicle entity %s', tostring(netId))
            return
        end

        if plate then
            SetVehicleNumberPlateText(vehicle, plate)
        end
        SetVehicleDoorsLocked(vehicle, 1)
        SetVehicleFuelLevel(vehicle, 100.0)
        SetVehicleDirtLevel(vehicle, 0.0)
    end)
end

local function applySession(payload)
    Job.starting = false
    Job.active = true
    Job.status = payload.status
    Job.currentDelivery = payload.currentDelivery
    Job.completedDeliveries = payload.completedDeliveries or 0
    Job.totalDeliveries = payload.totalDeliveries or 0
    Job.returnPoint = payload.returnPoint
    Job.vehicleNetId = payload.vehicleNetId
    Job.delivering = false

    configureWorkVehicle(payload.vehicleNetId, payload.vehiclePlate)
    updateRoute()
end

local function attemptDelivery()
    if Job.delivering or not Job.active or Job.status ~= Status.Delivering or not Job.currentDelivery then
        return
    end

    Job.delivering = true
    local ped = PlayerPedId()
    local coords = Job.currentDelivery.coords

    TaskTurnPedToFaceCoord(ped, coords.x, coords.y, coords.z, 500)
    Wait(500)
    TaskStartScenarioInPlace(ped, 'PROP_HUMAN_BUM_BIN', 0, true)
    QBCore.Functions.Notify('Entregando paquete...', 'primary', Config.Interaction.deliveryDurationMs)
    Wait(Config.Interaction.deliveryDurationMs)
    ClearPedTasks(ped)

    if not Job.active or Job.status ~= Status.Delivering then
        Job.delivering = false
        return
    end

    TriggerServerEvent(Events.CompleteDelivery)

    CreateThread(function()
        Wait(8000)
        if Job.delivering then
            Job.delivering = false
            QBCore.Functions.Notify('La validación tardó demasiado. Podés volver a intentarlo.', 'error')
        end
    end)
end

local function requestJobStart()
    if Job.active or Job.starting then
        return
    end

    Job.starting = true
    TriggerServerEvent(Events.RequestStart)

    CreateThread(function()
        Wait(Config.Interaction.requestTimeoutMs)
        if Job.starting and not Job.active then
            Job.starting = false
            QBCore.Functions.Notify('La solicitud de inicio tardó demasiado. Podés volver a intentarlo.', 'error')
        end
    end)
end

local function addDispatcherTarget()
    if dispatcherTargetRegistered or not dispatcherPed or not DoesEntityExist(dispatcherPed) then
        return
    end

    local targetAdded, targetError = pcall(function()
        exports['qb-target']:AddEntityZone(dispatcherTargetName, dispatcherPed, {
            name = dispatcherTargetName,
            debugPoly = Config.Debug
        }, {
            options = {
                {
                    icon = 'fas fa-truck-fast',
                    label = 'Iniciar trabajo de repartidor',
                    action = requestJobStart,
                    canInteract = function()
                        return not Job.active and not Job.starting
                    end
                },
                {
                    icon = 'fas fa-clipboard-check',
                    label = 'Finalizar turno',
                    action = function()
                        TriggerServerEvent(Events.FinishJob)
                    end,
                    canInteract = function()
                        return Job.active and Job.status == Status.AwaitingReturn
                    end
                },
                {
                    icon = 'fas fa-ban',
                    label = 'Cancelar turno',
                    action = function()
                        TriggerServerEvent(Events.CancelJob)
                    end,
                    canInteract = function()
                        return Job.active
                    end
                }
            },
            distance = Config.JobNPC.interactionDistance
        })
    end)

    if not targetAdded then
        print(('[ls-job-system] Failed to register dispatcher target: %s'):format(tostring(targetError)))
        return
    end

    dispatcherTargetRegistered = true
end

local function removeDispatcherTarget()
    if not dispatcherTargetRegistered then
        return
    end

    if GetResourceState('qb-target') == 'started' then
        local removed, removeError = pcall(function()
            exports['qb-target']:RemoveZone(dispatcherTargetName)
        end)
        if not removed then
            print(('[ls-job-system] Failed to remove dispatcher target: %s'):format(tostring(removeError)))
        end
    end

    dispatcherTargetRegistered = false
end

local function createDispatcherPed()
    local model = joaat(Config.JobNPC.model)

    if not IsModelInCdimage(model) or not IsModelValid(model) then
        print(('[ls-job-system] Invalid NPC model %s'):format(Config.JobNPC.model))
        return
    end

    RequestModel(model)

    local timeoutAt = GetGameTimer() + 10000
    while not HasModelLoaded(model) and GetGameTimer() < timeoutAt do
        Wait(50)
    end

    if not HasModelLoaded(model) then
        print(('[ls-job-system] Failed to load NPC model %s'):format(Config.JobNPC.model))
        SetModelAsNoLongerNeeded(model)
        return
    end

    local coords = Config.JobNPC.coords
    dispatcherPed = CreatePed(0, model, coords.x, coords.y, coords.z - 1.0, coords.w, false, false)
    if not dispatcherPed or dispatcherPed == 0 or not DoesEntityExist(dispatcherPed) then
        print(('[ls-job-system] Failed to create dispatcher NPC with model %s'):format(Config.JobNPC.model))
        dispatcherPed = nil
        SetModelAsNoLongerNeeded(model)
        return
    end

    SetEntityAsMissionEntity(dispatcherPed, true, true)
    SetEntityInvincible(dispatcherPed, true)
    SetBlockingOfNonTemporaryEvents(dispatcherPed, true)
    SetPedCanRagdoll(dispatcherPed, false)
    SetPedDiesWhenInjured(dispatcherPed, false)
    SetPedFleeAttributes(dispatcherPed, 0, false)
    FreezeEntityPosition(dispatcherPed, true)

    if Config.JobNPC.scenario and Config.JobNPC.scenario ~= '' then
        TaskStartScenarioInPlace(dispatcherPed, Config.JobNPC.scenario, 0, true)
    end

    SetModelAsNoLongerNeeded(model)
    addDispatcherTarget()
end

RegisterNetEvent(Events.SyncSession, function(payload, isNewSession)
    if type(payload) ~= 'table' then
        return
    end

    applySession(payload)
    if isNewSession and payload.vehicleNetId then
        QBCore.Functions.Notify('Tu vehículo de trabajo está listo junto al depósito.', 'primary')
    end
end)

RegisterNetEvent(Events.DeliveryAccepted, function(payload)
    if not Job.active or type(payload) ~= 'table' then
        return
    end

    Job.status = payload.status
    Job.currentDelivery = payload.currentDelivery
    Job.completedDeliveries = payload.completedDeliveries or Job.completedDeliveries
    Job.totalDeliveries = payload.totalDeliveries or Job.totalDeliveries
    Job.returnPoint = payload.returnPoint or Job.returnPoint
    Job.delivering = false
    updateRoute()
end)

RegisterNetEvent(Events.RequestRejected, function(message)
    Job.starting = false
    Job.delivering = false
    QBCore.Functions.Notify(message or 'La solicitud fue rechazada por el servidor.', 'error')
end)

RegisterNetEvent(Events.JobFinished, function(result)
    resetJobState()
    local reward = result and result.reward or 0
    QBCore.Functions.Notify(('Turno completado. Recibiste $%d.'):format(reward), 'success', 6500)

    if result and result.statsSaved == false then
        QBCore.Functions.Notify('El pago fue acreditado, pero no se pudieron actualizar las estadísticas.', 'error', 6500)
    end
end)

RegisterNetEvent(Events.JobCancelled, function()
    resetJobState()
    QBCore.Functions.Notify('Turno cancelado. No se acreditó ningún pago.', 'primary')
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent(Events.RequestState)
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    resetJobState()
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName == 'qb-target' and dispatcherPed and DoesEntityExist(dispatcherPed) then
        addDispatcherTarget()
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == 'qb-target' then
        dispatcherTargetRegistered = false
    end
end)

CreateThread(function()
    createDispatcherPed()

    while not NetworkIsPlayerActive(PlayerId()) do
        Wait(500)
    end

    TriggerServerEvent(Events.RequestState)
end)

CreateThread(function()
    while true do
        local sleep = 1000

        if Job.active and Job.status == Status.Delivering and Job.currentDelivery then
            local playerCoords = GetEntityCoords(PlayerPedId())
            local deliveryCoords = Job.currentDelivery.coords
            local distance = #(playerCoords - vector3(deliveryCoords.x, deliveryCoords.y, deliveryCoords.z))

            if distance <= Config.Interaction.drawDistance then
                sleep = 0
                local marker = Config.Interaction.marker
                DrawMarker(
                    marker.type,
                    deliveryCoords.x,
                    deliveryCoords.y,
                    deliveryCoords.z + 0.25,
                    0.0, 0.0, 0.0,
                    0.0, 180.0, 0.0,
                    marker.scale.x, marker.scale.y, marker.scale.z,
                    marker.color.r, marker.color.g, marker.color.b, marker.color.a,
                    false, true, 2, false, nil, nil, false
                )

                if distance <= Config.Interaction.deliveryDistance and not Job.delivering then
                    showHelpText('Presioná ~INPUT_CONTEXT~ para entregar el paquete')
                    if IsControlJustReleased(0, 38) then
                        attemptDelivery()
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    removeRouteBlip()

    removeDispatcherTarget()

    if dispatcherPed and DoesEntityExist(dispatcherPed) then
        DeleteEntity(dispatcherPed)
    end

    dispatcherPed = nil
    resetJobState()
end)
