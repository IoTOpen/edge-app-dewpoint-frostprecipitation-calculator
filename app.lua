local createFunction = false
local devices = {}
local topicMap = {}
local CONFIG = {
    DECODER_NAME = "decentlab.dlwrm",
    -- Maximum age of measurements to consider valid (in milliseconds)
    MAX_AGE_MS = 10000 * 1, -- 5 minutes
    REQUIRED_MEASUREMENTS = {
        "air_temperature",
        "air_humidity",
        "surface_temperature",
        "head_temperature"
    },
    -- Topics for publishing results
    PUBLISH_TOPICS = {
        dewPoint = "obj/lora/%s/dew_point",
        frostPrecipitation = "obj/lora/%s/frost_precipitation"
    }
}

local measurements = {
    data = {
        air_temperature = nil,
        air_humidity = nil,
        surface_temperature = nil,
        head_temperature = nil
    },
    timestamps = {}
}

-- get all functions with type value-transformer, if 0 create call createFucntions
local function checkIfFunctionExist(eui, topic)
    print("check if finction exist on device", string.format('obj/lora/%s/%s', eui, topic))
    local functions = lynx.getFunctions({
        topic_read = string.format('obj/lora/%s/%s', eui, topic)
    })
    if #functions > 0 then
        return true
    end
    print("false")
    return false
end


local function createFunctions()
    devs = edge.findDevices({ ["lora_manager.decoder_name"] = "decentlab.dlwrm" })

    topics = {
        "dew_point",
        "frost_precipitation"
    }
    -- Loop trough devices
    for _, dev in ipairs(devs) do
        -- for each topic create function
        for _, topic in ipairs(topics) do
            if checkIfFunctionExist(dev.meta.eui, topic) == false then
                print("creating function", topic, dev)
                local fn = {
                    type = topic,
                    installation_id = app.installation_id,
                    meta = {
                        device_id = tostring(dev.id),
                        eui = dev.meta.eui,
                        name = string.format('%s - %s', dev.meta.eui, topic),
                        topic_read = string.format('obj/lora/%s/%s', dev.meta.eui, topic)

                    }
                }
                if topic == "dew_point" then
                    fn.meta.unit = "°C"
                    fn.meta.format = "%.1f°C"
                end
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
    return dewPoint
end

-- Function to check for frost precipitation conditions
local function checkFrostPrecipitation(surfaceTemp, dewPoint)
    local result = {
        isFrostPossible = 0, -- false
        reason = "",
    }

    -- Check if surface temperature is below freezing
    if surfaceTemp <= 0 then
        -- Check if surface temperature is below dew point
        if surfaceTemp <= dewPoint then
            result.isFrostPossible = 1 -- true
            result.reason = "Surface temperature is below both freezing and dew point"
        else
            result.reason = "Surface temperature is below freezing but above dew point"
        end
    else
        result.reason = "Surface temperature is above freezing"
    end

    return result
end

local function processWeatherData(airTemp, humidity, surfaceTemp)
    local dewPoint = calculateDewPoint(airTemp, humidity)
    local frostResult = checkFrostPrecipitation(surfaceTemp, dewPoint)

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

-- Helper function to clean old measurements
local function cleanOldMeasurements()
    local now = edge:time() -- current time in ms
    for topic, timestamp in pairs(measurements.timestamps) do
        if (now - timestamp) > CONFIG.MAX_AGE_MS then
            measurements.data[topic] = nil
            measurements.timestamps[topic] = nil
        end
    end
end

-- function to check if we have all required measurements
local function hasAllMeasurements()
    for _, measurement in ipairs(CONFIG.REQUIRED_MEASUREMENTS) do
        if measurements.data[measurement] == nil then
            return false
        end
    end
    return true
end

-- check if measurements are within acceptable time window
local function measurementsInTimeWindow()
    local oldest = math.huge
    local newest = 0

    for _, timestamp in pairs(measurements.timestamps) do
        oldest = math.min(oldest, timestamp)
        newest = math.max(newest, timestamp)
    end

    return (newest - oldest) <= CONFIG.MAX_AGE_MS
end

-- read function data, perform action depending on logic
local function handleMessage(topic, payload)
    local fun = topicMap[topic]
    if fun == nil then
        return
    end

    local data = json:decode(payload)
    local timestamp = edge:time() -- current time in ms

    -- Store measurement with timestamp
    local measurementType = fun.meta["lora_type"]
    measurements.data[measurementType] = data.value
    measurements.timestamps[measurementType] = timestamp


    -- Clean any old measurements
    cleanOldMeasurements()

    -- Check if we have all required measurements within time window
    if hasAllMeasurements() and measurementsInTimeWindow() then
        local eui = fun.meta["eui"]
        local airTemp = measurements.data["air_temperature"]
        local humidity = measurements.data["air_humidity"]
        local surfaceTemp = measurements.data["surface_temperature"]
        local headTemp = measurements.data["head_temperature"]

        local dewPointData, forstRiskData = processWeatherData(airTemp, humidity, surfaceTemp, headTemp)

        -- Publish each result to its respective topic
        publishResult(eui, CONFIG.PUBLISH_TOPICS.dewPoint, dewPointData)
        publishResult(eui, CONFIG.PUBLISH_TOPICS.frostPrecipitation, forstRiskData)

        -- Clear processed measurements
        measurements.data = {}
        measurements.timestamps = {}
    end
end



-- when new values arrive on filtered topics
function onFunctionsUpdated()
    -- First, unsubscribe from all existing topics
    for topic, _ in pairs(topicMap) do
        mq:unsub(topic)
    end

    -- clear map
    topicMap = {}

    -- find specified functions using filters in cfg
    local funs = edge.findFunctions(cfg.functions)
    -- for each function
    for _, fun in ipairs(funs) do
        -- check metadata
        for k, v in pairs(fun.meta) do
            -- look for topic_read, store topic and subscribe
            if k:sub(1, #"topic_read") == "topic_read" then
                topicMap[v] = fun
                mq:sub(v, 0)
            end
        end
    end
end

function onStart()
    createFunctions()
    mq:bind("#", handleMessage)
    onFunctionsUpdated()
end
