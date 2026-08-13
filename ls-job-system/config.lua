Config = {}

Config.Debug = false

Config.JobNPC = {
    model = 's_m_m_postal_01',
    coords = vector4(-425.57, -2789.08, 6.53, 43.67),
    scenario = 'WORLD_HUMAN_CLIPBOARD',
    interactionDistance = 2.0
}

Config.WorkVehicle = {
    enabled = true,
    model = 'speedo',
    type = 'automobile',
    spawn = vector4(-432.85, -2783.76, 6.00, 45.0),
    spawnClearance = 3.0,
    platePrefix = 'LSD',
    plateDigits = 5,
    plateGenerationAttempts = 10,
    networkEntityTimeoutMs = 7500,
    requireAtReturn = true,
}

Config.ReturnPoint = {
    coords = vector3(-425.57, -2789.08, 6.53),
    validationDistance = 8.0
}

Config.DeliveriesPerJob = {
    min = 4,
    max = 7
}

Config.DeliveryLocations = {
    { id = 'davis_01', label = 'Davis Avenue', coords = vector3(126.73, -1929.92, 21.38) },
    { id = 'forum_01', label = 'Forum Drive', coords = vector3(-14.11, -1441.63, 31.10) },
    { id = 'vespucci_01', label = 'Vespucci Boulevard', coords = vector3(-1076.61, -1026.95, 4.54) },
    { id = 'del_perro_01', label = 'Del Perro', coords = vector3(-1265.66, -653.02, 26.86) },
    { id = 'hawick_01', label = 'Hawick Avenue', coords = vector3(-595.69, 37.74, 43.61) },
    { id = 'rockford_01', label = 'Rockford Hills', coords = vector3(-713.97, 264.20, 84.14) },
    { id = 'vinewood_01', label = 'Vinewood Hills', coords = vector3(318.50, 561.10, 154.90) },
    { id = 'mirror_01', label = 'Mirror Park', coords = vector3(1204.89, -557.78, 69.62) },
    { id = 'mirror_02', label = 'Nikola Avenue', coords = vector3(1265.60, -648.85, 67.92) },
    { id = 'mirror_03', label = 'West Mirror Drive', coords = vector3(959.93, -669.62, 58.45) },
    { id = 'strawberry_01', label = 'Strawberry Avenue', coords = vector3(185.20, -1686.43, 29.29) },
    { id = 'mission_01', label = 'Mission Row', coords = vector3(291.48, -1078.13, 29.41) }
}

Config.Validation = {
    deliveryDistance = 5.0,
    startDistance = 5.0,
    eventCooldownMs = 750,
    startCooldownMs = 2000,
    stateSyncCooldownMs = 1000
}

Config.Rewards = {
    account = 'bank',
    perDelivery = { min = 180, max = 240 },
    completionBonus = 300
}

Config.Interaction = {
    deliveryDistance = 2.0,
    drawDistance = 35.0,
    deliveryDurationMs = 1800,
    requestTimeoutMs = 8000,
    marker = {
        type = 2,
        scale = vector3(0.35, 0.35, 0.35),
        color = { r = 255, g = 184, b = 77, a = 190 }
    }
}

Config.Blips = {
    delivery = { sprite = 1, color = 5, scale = 0.85, label = 'Entrega pendiente' },
    returnPoint = { sprite = 478, color = 2, scale = 0.85, label = 'Volver al depósito' }
}
