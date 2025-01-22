# edge-app-dewpoint-frostprecipitation-calculator
edge app to calculate dewpoint and frost precipitation using data from DL-WRM002.

#### Input sensor data:
air_temperature
air_humidity
surface_temperature
head_temperature*

\*head_temperature is not currently being used in the app. It is included if the logic of the app would need to be expanded in the future.

### Dewpoint
Dewpoint is calcualted using Magnus formula:

$$ γ = ((17.27 * T) / (237.7 + T)) + ln(RH/100) $$\
$$ Td = (237.7 * γ) / (17.27 - γ)$$

T = Air temperature in °C\
RH = Air humidity in %\
Td = Dew point temperature in °C

Constants being used:
a = 17.27
b = 237.7

[Reference](https://en.wikipedia.org/wiki/Dew_point)
#### Code:
```lua
    -- Constants for Magnus formula
    local a = 17.27
    local b = 237.7
    -- Calculate gamma term
    local gamma = ((a * airTemp) / (b + airTemp)) + math.log(relativeHumidity / 100.0)
    -- Calculate dew point
    local dewPoint = (b * gamma) / (a - gamma)
    return dewPoint
```

### Frost Precipitation
Logic for calculating frost precipitation, make use of calculated dew point and surface temperature.

0 = No frost\
1 = Frost is possible

```lua
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
```

## Output Topics
The edge-app publishes to two topics (replace `%s` with device EUI):

Dew point: `obj/lora/%s/dew_point` \
Frost precipitation: `obj/lora/%s/frost_precipitation`