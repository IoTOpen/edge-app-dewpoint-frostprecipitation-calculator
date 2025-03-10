local CONFIG = {
    -- Topics for publishing results
    PUBLISH_TOPICS = {
        dewPoint = "obj/lora/%s/dew_point",
        frostPrecipitation = "obj/lora/%s/frost_precipitation"
    },
    -- type of output function
    OUTPUT_FUNCTIONS_TYPE = {
        "dew_point",
        "frost_precipitation"
    }
}

local requiredMeasurements = {} -- contains functions that will be read
local topicFunctionMap = {}     -- stores function data and metadata
local measurements = {}         -- stores measurement data from fucntions
local lastFrostState = {}

-- check if necessary output functions exist on devices
local function shouldFunctionBeCreated(eui, topic)
    print("function exist on device", string.format('obj/lora/%s/%s', eui, topic))
    local functions = lynx.getFunctions({
        topic_read = string.format('obj/lora/%s/%s', eui, topic)
    })

    if #functions > 0 then -- if number of functions we looking is more then 0 and input functions is more then 2
        return false
    end
    return true
end

-- create necessary functions on devices
local function createOutputFunctions()
    print("create function")
    devs = edge.findDevices(cfg.devices) -- use the devices selected by user
    -- Loop trough devices
    for _, dev in ipairs(devs) do
        -- for each output funcition type create a new function
        for _, outFun in ipairs(CONFIG.OUTPUT_FUNCTIONS_TYPE) do
            local eui = dev.meta.eui
            local count = 0
            for d in pairs(measurements[eui].data) do
                print(eui, d)
                count = count + 1
            end
            if shouldFunctionBeCreated(dev.meta.eui, outFun) == true and count > 2 then -- check if functions should be created and if there is enough input topics
                local fn = {
                    type = outFun,
                    installation_id = app.installation_id,
                    meta = {
                        device_id  = tostring(dev.id),
                        eui        = dev.meta.eui,
                        name       = string.format('%s - %s', dev.meta.eui, outFun),
                        topic_read = string.format('obj/lora/%s/%s', dev.meta.eui, outFun),
                        app_id     = tostring(app.id),
                        lora_type  = outFun
                    }
                }
                if outFun == "dew_point" then
                    fn.meta.unit = "°C"
                    fn.meta.format = "%.1f°C"
                end
                print("creating function", outFun, dev, dev.meta.eui)
                lynx.createFunction(fn)
            end
        end
    end
end

-- Function to calculate dew point using Magnus formula
local function calculateDewPoint(airTemp, relativeHumidity)
    -- Constants for Magnus formula
    local a = 17.27
    local b = 237.7
    -- Calculate gamma term
    local gamma = ((a * airTemp) / (b + airTemp)) + math.log(relativeHumidity / 100.0)
    -- Calculate dew point
    local dewPoint = (b * gamma) / (a - gamma)
    -- round to 1 decimal place
    dewPoint = math.floor(dewPoint * 10 + 0.5) / 10
    return dewPoint
end

-- Function to check for frost precipitation conditions
-- https://www.weather.gov/source/zhu/ZHU_Training_Page/fog_stuff/Dew_Frost/Dew_Frost.htm
local function checkFrostPrecipitation(surfaceTemp, dewPoint, airTemp)
    local result = {
        isFrostPossible = 0,
        reason = ""
    }

    -- No frost risk if surface temperature is above freezing
    if surfaceTemp > 0 then
        result.reason = string.format(
            "No frost risk. Surface temperature (%.1f°C) is above freezing",
            surfaceTemp
        )
        return result
    end

    -- Calculate moisture availability (difference between air temperature and dew point)
    local moistureAvailability = airTemp - dewPoint

    -- High risk: freezing + high humidity/close dew point
    if moistureAvailability < 1.0 then
        result.isFrostPossible = 1
        result.reason = string.format(
            "High frost risk! Surface temperature (%.1f°C) is below freezing with high moisture availability (dew point %.1f°C)",
            surfaceTemp, dewPoint
        )
        -- Medium risk: freezing but moderate humidity
    elseif moistureAvailability < 3.0 then
        result.isFrostPossible = 1
        result.reason = string.format(
            "Moderate frost risk. Surface temperature (%.1f°C) is below freezing with moderate moisture availability",
            surfaceTemp
        )
        -- Low/no risk: freezing but dry conditions
    else
        result.reason = string.format(
            "Minimal frost risk. Surface temperature (%.1f°C) is below freezing but conditions are too dry for significant frost",
            surfaceTemp
        )
    end

    return result
end

local function processWeatherData(airTemp, humidity, surfaceTemp)
    local dewPoint = calculateDewPoint(airTemp, humidity)
    local frostResult = checkFrostPrecipitation(surfaceTemp, dewPoint, airTemp)

    -- Prepare return data structures
    local dewPointData = {
        val = dewPoint,
        msg = string.format("Dew point: %.1f°C", dewPoint)
    }

    local frostRiskData = {
        val = frostResult.isFrostPossible,
        msg = frostResult.reason
    }

    return dewPointData, frostRiskData
end

-- function to check if we have all required measurements
local function hasAllMeasurements(eui)
    for _, m in ipairs(requiredMeasurements[eui]) do
        if measurements[eui].data[m] == false then
            return false
        end
    end
    return true
end

-- function to publish a single result
local function publishResult(eui, topicTemplate, data)
    local topic = string.format(topicTemplate, eui)
    local payload = json:encode({
        value = data.val,
        msg = data.msg,
        timestamp = edge:time()
    })
    mq:pub(topic, payload, false, 0)
end

-- read function data, perform action depending on logic
local function handleMessage(topic, payload)
    local fun = topicFunctionMap[topic]
    if fun == nil then
        return
    end

    local data = json:decode(payload)
    local timestamp = edge:time() -- current time in ms
    local devEui = fun.meta["eui"]
    -- Store measurement with timestamp
    local measurementType = fun.meta["lora_type"]
    measurements[devEui].data[measurementType] = data.value
    measurements[devEui].timestamps[measurementType] = timestamp

    -- Check if we have all required measurements to calculate
    if hasAllMeasurements(devEui) then
        local airTemp = ""
        local humidity = ""
        local surfaceTemp = ""
        for key, value in pairs(measurements[devEui].data) do
            if string.find(key, "surface") or string.find(key, "ext_temp") then
                surfaceTemp = value
            elseif string.find(key, "humid") then
                humidity = value
            elseif string.find(key, "air_temp") or string.match(key, "^temperature$") then
                airTemp = value
            end
            measurements[devEui].data[key] = false -- reset value after storing it
        end
        local dewPointData, forstRiskData = processWeatherData(airTemp, humidity, surfaceTemp)

        -- Always publish dew point
        publishResult(devEui, CONFIG.PUBLISH_TOPICS.dewPoint, dewPointData)
        publishResult(devEui, CONFIG.PUBLISH_TOPICS.frostPrecipitation, forstRiskData)

        -- Clear processed measurements
        measurements[devEui].timestamps = {}
        if lastFrostState[devEui] ~= forstRiskData.val then -- if value has toggled
            print("frost state has changed: ", devEui, " from ", lastFrostState[devEui], " to ", forstRiskData.val)
            -- store new value
            lastFrostState[devEui] = forstRiskData.val
            if lastFrostState[devEui] == 1 then -- only send notification if frost risk is present
                device = edge.findDevice({ eui = devEui })


                local notifyPayload = {
                    device_name = device.meta.name,
                    wrm_grafana_name = device.meta.WRM_grafana_name,
                    device_id = device.id,
                    device_eui = devEui,
                    humidity = humidity,
                    air_temperature = airTemp,
                    surface_temperature = surfaceTemp,
                    dew_point = dewPointData.val,
                    value = forstRiskData.val,
                    msg = forstRiskData.msg,
                    timestamp = edge:time()
                }
                print(os.date("%Y-%m-%d %H:%M:%S", notifyPayload.timestamp), " Sending notification for device", devEui,
                    "with data", json:encode(notifyPayload))
                lynx.notify(cfg.notification_output, notifyPayload)
            end
        end
    end
end

-- find necessary functions
function findFunctions()
    local funs = {}

    -- First, get all the selected device EUIs from cfg.devices
    local selectedDeviceEUIs = {}
    local devs = edge.findDevices(cfg.devices)
    for _, dev in ipairs(devs) do
        selectedDeviceEUIs[dev.meta.eui] = true
    end

    -- Iterate through each EUI and its measurements
    for eui, measurements in pairs(requiredMeasurements) do
        -- Only process if this EUI belongs to a selected device
        if selectedDeviceEUIs[eui] then
            -- Iterate through each measurement type for this EUI
            for _, measurementType in ipairs(measurements) do
                -- Find the function for this measurement type
                local func = edge.findFunction({ lora_type = measurementType, eui = eui })
                if func then
                    table.insert(funs, func)
                end
            end
        end
    end
    return funs
end

-- when new values arrive on filtered topics
function onFunctionsUpdated()
    print("update function")
    -- First, unsubscribe from all existing topics
    for topic, _ in pairs(topicFunctionMap) do
        print("unsub from", topic)
        mq:unsub(topic)
    end

    -- clear map
    topicFunctionMap = {}

    -- get selected functions
    local funs = findFunctions()
    -- subscribe to each function
    for _, fun in ipairs(funs) do
        tr = fun.meta.topic_read
        topicFunctionMap[tr] = fun
        print("subscribe to: ", tr)
        mq:sub(tr, 0)
    end
end

function getInputFunctions()
    print("getInputFunctions")
    funs = edge.findFunctions(cfg.functions)
    for _, fun in ipairs(funs) do
        name = fun.meta["lora_type"]
        eui = fun.meta["eui"]
        if not measurements[eui] then
            measurements[eui] = {
                data = {},
                timestamps = {}
            }
        end
        if not requiredMeasurements[eui] then
            requiredMeasurements[eui] = {}
        end

        -- Add the measurement requirement for this specific EUI
        table.insert(requiredMeasurements[eui], name)
        measurements[eui].data[name] = false
        measurements[eui].timestamps[name] = os.time() * 1000
    end
end

function onStart()
    local startTime = os.time()
    print("Edge-app started ", os.date("%Y-%m-%d %H:%M:%S", startTime))
    getInputFunctions()
    createOutputFunctions()
    mq:bind("#", handleMessage)
    onFunctionsUpdated()
end
