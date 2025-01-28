# edge-app-dewpoint-frostprecipitation-calculator
edge app to calculate dewpoint and frost precipitation.
Users choose for what devices calculations should be made and what functions to include. <strong>If not necessary input data is included the calculation wont work.</strong>

#### Necessary Input sensor data:
air_temperature (or similar) = <em>temperature in the air</em>\
air_humidity (or similar) = <em>humidity in the air</em>\
surface_temperature (or similar) = <em>temperature of the surface we want to check for frost. </em>\


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

If the surface temperature is below freezing and below dew point then we can assume there is a risk for frost. Otherwise we assume there is no risk or very unlikely.

#### Code

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