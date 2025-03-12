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
    },
    -- Add inertia configuration
    FROST_INERTIA = {
        REQUIRED_CLEAR_TIME_MS = 1800000, -- 30 minutes in milliseconds
        MIN_SAMPLES = 3                   -- minimum number of clear samples required
    }
}

local requiredMeasurements = {} -- contains functions that will be read
local topicFunctionMap = {}     -- stores function data and metadata
local measurements = {}         -- stores measurement data from fucntions
local lastFrostState = {}
local frostClearTracking = {}   -- tracks consecutive clear conditions per device

-- check if necessary output functions exist on devices
local function shouldFunctionBeCreated(eui, topic)
    local functions = lynx.getFunctions({
        topic_read = string.format('obj/lora/%s/%s', eui, topic)
    })

    if #functions > 0 then -- if number of functions we looking is more then 0 and input functions is more then 2
        print(string.format("Function %s already exist on device", string.format('obj/lora/%s/%s', eui, topic)))
        return false
    end
    print(string.format("Function %s is missing on device", string.format('obj/lora/%s/%s', eui, topic)))
    return true
end

-- create necessary functions on devices
function CreateOutputFunctions()
    print("Create functions")
    devs = edge.findDevices(cfg.devices) -- use the devices selected by user
    -- Loop trough devices
    for _, dev in ipairs(devs) do
        -- for each output funcition type create a new function
        for _, outFun in ipairs(CONFIG.OUTPUT_FUNCTIONS_TYPE) do
            local eui = dev.meta.eui
            local count = 0
            print("Check if necessary functions was included:")
            for i in pairs(measurements[eui]) do
                print(eui, i)
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
                print(string.format("Creating functions %s on device %s", outFun, dev.meta.eui))
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

    -- No frost risk if surface temperature is well above freezing
    if surfaceTemp > 1 then
        result.reason = string.format(
            "No calculated frost risk. Surface temperature (%.1f°C) is well above threshold",
            surfaceTemp
        )
        return result
    end

    -- Calculate moisture availability (difference between air temperature and dew point)
    local moistureAvailability = airTemp - dewPoint

    -- High risk: freezing + high humidity/close dew point
    if moistureAvailability <= 1.0 then -- High risk (RH ~90-100%)
        result.isFrostPossible = 1
        result.reason = string.format(
            "Calculated frost risk is high! Surface temperature is %.1f°C is below threshold with high moisture availability (dew point %.1f°C)",
            surfaceTemp, dewPoint
        )
        -- Medium risk: freezing but moderate humidity
    elseif moistureAvailability < 3.0 then -- Medium risk (RH ~70-90%)
        result.isFrostPossible = 1
        result.reason = string.format(
            "Calculated frost risk is moderate. Surface temperature (%.1f°C) is below threshold with moderate moisture availability (dew point %.1f°C)",
            surfaceTemp, dewPoint
        )
        -- Low/no risk: freezing but dry conditions
    else -- Low/no risk (RH <70%)
        result.isFrostPossible = 1
        result.reason = string.format(
            "Calculated frost risk is minimal. Surface temperature (%.1f°C) is below threshold but conditions are too dry for significant frost (dew point %.1f°C)",
            surfaceTemp, dewPoint
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
        if measurements[eui][m].value == false then
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

-- Updated function to handle frost inertia/hysteresis
local function handleFrostState(devEui, frostRiskData, measData, dewPointData)
    local now = os.time() * 1000

    if frostRiskData.val == 1 then
        frostClearTracking[devEui] = nil

        -- Only notify on transition from non-frost to frost state
        if lastFrostState[devEui] ~= 1 then
            print(string.format("%s Frost state changed for %s from %s -> 1",
                Timestamp(), devEui, lastFrostState[devEui]))
            lastFrostState[devEui] = 1
            SendNotification(devEui, measData, dewPointData, frostRiskData)
        end
    else -- frostRiskData.val == 0
        if lastFrostState[devEui] == 1 then
            if not frostClearTracking[devEui] then
                frostClearTracking[devEui] = {
                    firstClearTime = now,
                    clearCount = 1
                }
                print(string.format("%s Device %s: Starting frost clear tracking", Timestamp(), devEui))
            else
                frostClearTracking[devEui].clearCount = frostClearTracking[devEui].clearCount + 1
                local clearDuration = now - frostClearTracking[devEui].firstClearTime
                print(string.format("%s Device %s: Clear count: %d, duration: %.1f minutes",
                    Timestamp(), devEui, frostClearTracking[devEui].clearCount, clearDuration / 60000))

                if frostClearTracking[devEui].clearCount >= CONFIG.FROST_INERTIA.MIN_SAMPLES and
                    clearDuration >= CONFIG.FROST_INERTIA.REQUIRED_CLEAR_TIME_MS then
                    print(string.format("%s Frost state cleared for %s after inertia period", Timestamp(), devEui))
                    lastFrostState[devEui] = 0
                    frostClearTracking[devEui] = nil
                    -- No notification sent when frost clears, per requirement
                end
            end
        end
    end
end

-- Helper function to create and send frost notification payload
function SendNotification(devEui, measData, dewPointData, frostRiskData)
    local device = edge.findDevice({ eui = devEui })
    if not device then
        print(string.format("%s Device not found for EUI %s. Skipping notification..", Timestamp(), devEui))
        return
    end

    if measData.airTemp == "" or measData.humidity == "" or measData.surfaceTemp == "" then
        print(string.format("%s Missing data for device %s. Skipping notification..", Timestamp(), devEui))
        return
    end

    local notifyPayload = {
        device_name = device.meta.name,
        wrm_grafana_name = device.meta.WRM_grafana_name,
        device_id = device.id,
        device_eui = devEui,
        humidity = measData.humidity,
        air_temperature = measData.airTemp,
        surface_temperature = measData.surfaceTemp,
        dew_point = dewPointData.val,
        value = frostRiskData.val,
        msg = frostRiskData.msg,
        timestamp = edge:time()
    }

    print(string.format("%s Sending frost notification for device %s:\n%s",
        Timestamp(), devEui, json:encode(notifyPayload)))

    if cfg.notification_output then
        lynx.notify(cfg.notification_output, notifyPayload)
    else
        print("Notification output not configured, not sent..")
    end
end

-- Simplified handleMessage function (replace the existing one)
local function handleMessage(topic, payload)
    local fun = topicFunctionMap[topic]
    if fun == nil then
        return
    end

    local data = json:decode(payload)
    local timestamp = edge:time()
    local devEui = fun.meta["eui"]
    local measurementType = fun.meta["lora_type"]
    print(string.format("Handlemessage: %s - %s: %s", devEui, measurementType, data.value))

    -- Apply offset if exists for temperature measurements
    local value = data.value
    local measurement = measurements[devEui][measurementType]
    if measurement.offset ~= 0 then
        print(string.format("Applying offset %.1f to %s Original: %.1f -> New: %.1f",
            measurement.offset, measurementType, value, value + measurement.offset))
        value = value + measurement.offset
    end

    measurements[devEui][measurementType].value = value
    measurements[devEui][measurementType].timestamp = timestamp

    if hasAllMeasurements(devEui) then
        local airTemp = ""
        local humidity = ""
        local surfaceTemp = ""

        -- Collect measurements (offsets already applied)
        for key, m in pairs(measurements[devEui]) do
            local val = m.value
            if string.find(key, "surface") or string.find(key, "ext_temp") then
                surfaceTemp = val
            elseif string.find(key, "humid") then
                humidity = val
            elseif string.find(key, "air_temp") or string.match(key, "^temperature$") then
                airTemp = val
            end
            m.value = false -- reset value after storing it
        end

        -- Process weather data
        local dewPointData, frostRiskData = processWeatherData(airTemp, humidity, surfaceTemp)

        print(string.format("%s Publishing dew point: %.1f°C, Frost risk: %s",
            Timestamp(), dewPointData.val, frostRiskData.msg))
        --publishResult(devEui, CONFIG.PUBLISH_TOPICS.dewPoint, dewPointData)
        --publishResult(devEui, CONFIG.PUBLISH_TOPICS.frostPrecipitation, frostRiskData)

        -- Clear processed measurements
        measurements[devEui].timestamps = {}

        -- Handle frost state changes with inertia (all state management happens here)
        handleFrostState(
            devEui,
            frostRiskData,
            { humidity = humidity, airTemp = airTemp, surfaceTemp = surfaceTemp },
            dewPointData
        )
    end
end

function Timestamp()
    return os.date("[%Y-%m-%d %H:%M:%S]")
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
    for eui, mes in pairs(requiredMeasurements) do
        -- Only process if this EUI belongs to a selected device
        if selectedDeviceEUIs[eui] then
            -- Iterate through each measurement type for this EUI
            for _, measurementType in ipairs(mes) do
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
    -- First, unsubscribe from all existing topics
    for topic, _ in pairs(topicFunctionMap) do
        print(string.format("Unsubscribing from %s", topic))
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
        print(string.format("Subscribed to %s", tr))
        mq:sub(tr, 0)
    end
end

function collectOffsets()
    for _, repeatGroup in pairs(cfg.repeat_nestled) do
        if repeatGroup.repeat_in_repeat then
            for _, item in pairs(repeatGroup.repeat_in_repeat) do
                local functionId = item.single_function_selector_temperature
                local offset = item.number_default
                local func = edge.findFunction({ id = functionId })
                if func then
                    local eui = func.meta.eui
                    local measurementType = func.meta.lora_type

                    if measurements[eui] and measurements[eui][measurementType] then
                        measurements[eui][measurementType].offset = offset
                        print(string.format("Collected offset %.1f for %s", offset, measurementType))
                    end
                end
            end
        end
    end
end

function GetInputFunctions()
    funs = edge.findFunctions(cfg.functions)
    for _, fun in ipairs(funs) do
        name = fun.meta["lora_type"]
        eui = fun.meta["eui"]
        if not measurements[eui] then
            measurements[eui] = {}
        end
        if not requiredMeasurements[eui] then
            requiredMeasurements[eui] = {}
        end

        -- Add the measurement requirement for this specific EUI
        table.insert(requiredMeasurements[eui], name)
        measurements[eui][name] = {
            value = false,
            offset = 0,
            timestamp = os.time() * 1000
        }
    end

    collectOffsets()
    print("Measurements stored:")
    PrintTable(measurements)
end

function PrintTable(t, indent)
    indent = indent or 0
    local indentStr = string.rep("  ", indent)

    for k, v in pairs(t) do
        local kStr = tostring(k)
        if type(v) == "table" then
            print(indentStr .. kStr .. ":")
            PrintTable(v, indent + 1)
        else
            print(indentStr .. kStr .. " = " .. tostring(v))
        end
    end
end

function onStart()
    print(string.format("%s Edge-app started", Timestamp()))
    GetInputFunctions()
    CreateOutputFunctions()
    mq:bind("#", handleMessage)
    onFunctionsUpdated()
end
