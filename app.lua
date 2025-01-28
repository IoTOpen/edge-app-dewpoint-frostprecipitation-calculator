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



-- check if necessary output functions exist on devices
local function checkIfFunctionExist(eui, topic)
    print("function exist on device", string.format('obj/lora/%s/%s', eui, topic))
    local functions = lynx.getFunctions({
        topic_read = string.format('obj/lora/%s/%s', eui, topic)
    })
    if #functions > 0 then
        return true
    end
    return false
end

-- create necessary functions on devices
local function createOutputFunctions()
    print("create function")
    devs = edge.findDevices(cfg.devices) -- use the devices selected by user
    -- Loop trough devices
    for _, dev in ipairs(devs) do
        -- for each output funcition type create a new function
        for _, outFun in ipairs(CONFIG.OUTPUT_FUNCTIONS_TYPE) do
            if checkIfFunctionExist(dev.meta.eui, outFun) == false then
                print("creating function", outFun, dev)
                local fn = {
                    type = outFun,
                    installation_id = app.installation_id,
                    meta = {
                        device_id  = tostring(dev.id),
                        eui        = dev.meta.eui,
                        name       = string.format('%s - %s', dev.meta.eui, outFun),
                        topic_read = string.format('obj/lora/%s/%s', dev.meta.eui, outFun),
                        app_id     = tostring(app.id)
                    }
                }
                if outFun == "dew_point" then
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
            result.reason = "Risk for frost! Surface temperature is below both freezing and dew point"
        else
            result.reason = "Surface temperature is below freezing but above dew point"
        end
    else
        result.reason = "No risk for frost. Surface temperature is above freezing"
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
    print("publish")
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
    local eui = fun.meta["eui"]
    -- Store measurement with timestamp
    local measurementType = fun.meta["lora_type"]
    measurements[eui].data[measurementType] = data.value
    measurements[eui].timestamps[measurementType] = timestamp

    -- Check if we have all required measurements to calculate
    if hasAllMeasurements(eui) then
        local airTemp = ""
        local humidity = ""
        local surfaceTemp = ""
        for key, value in pairs(measurements[eui].data) do
            if string.find(key, "surface") or string.find(key, "ext_temp") then
                surfaceTemp = value
            elseif string.find(key, "humid") then
                humidity = value
            elseif string.find(key, "air_temp") or string.match(key, "^temperature$") then
                airTemp = value
            end
            measurements[eui].data[key] = false -- reset value after storing it
        end
        local dewPointData, forstRiskData = processWeatherData(airTemp, humidity, surfaceTemp)

        -- Publish each result to its respective topic obj/lora/<eui>/<topic>
        publishResult(eui, CONFIG.PUBLISH_TOPICS.dewPoint, dewPointData)
        publishResult(eui, CONFIG.PUBLISH_TOPICS.frostPrecipitation, forstRiskData)

        -- Clear processed measurements
        measurements[eui].timestamps = {}
    end
end

-- find necessary functions
function findFunctions()
    local funs = {}

    -- Iterate through each EUI and its measurements
    for eui, measurements in pairs(requiredMeasurements) do
        -- Iterate through each measurement type for this EUI
        for _, measurementType in ipairs(measurements) do
            -- Find the function for this measurement type
            local func = edge.findFunction({ lora_type = measurementType, eui = eui })
            if func then
                table.insert(funs, func)
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
        print("subsribe to: ", tr)
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
    getInputFunctions()
    createOutputFunctions()
    mq:bind("#", handleMessage)
    onFunctionsUpdated()
end

-- delete functions when edge app
function onDestroy()
    local funs = edge.findFunctions({ app_id = app.id })
    for _, fun in ipairs(funs) do
        if fun ~= nil then
            print("deleting function", fun.id)
            lynx.deleteFunction(fun.id)
        end
    end
end
