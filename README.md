# edge-app-dewpoint-frostprecipitation-calculator

Edge-app that calculate dew point and frost precipitation.

Users choose for what devices calculations should be made and what functions to be used for calculations. <strong>If not necessary input data is included the calculation wont work.</strong> When setting up the app, functions it doesn't think are needed will be filtered out. If this app is used with another sensors then Decentlab or Elsys this might need to be updated.
Edge-app also can send notification when frost precipitation is happening (value is 1)

#### Necessary Input sensor data

air_temperature (or similar) = <em>temperature in the air</em>\
air_humidity (or similar) = <em>humidity in the air</em>\
surface_temperature (or similar) = <em>temperature of the surface we want to check for frost. </em>

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

#### Code

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
    if moistureAvailability <= 1.0 then -- High risk (RH ~90-100%)
        result.isFrostPossible = 1
        result.reason = string.format(
            "High frost risk! Surface temperature is %.1f°C is below with high moisture availability (dew point %.1f°C)",
            surfaceTemp, dewPoint
        )
        -- Medium risk: freezing but moderate humidity
    elseif moistureAvailability < 3.0 then -- Medium risk (RH ~70-90%)
        result.isFrostPossible = 1
        result.reason = string.format(
            "Moderate frost risk. Surface temperature (%.1f°C) is below freezing with moderate moisture availability (dew point %.1f°C)",
            surfaceTemp, dewPoint
        )
        -- Low/no risk: freezing but dry conditions
    else -- Low/no risk (RH <70%)
        result.reason = string.format(
            "Minimal frost risk. Surface temperature (%.1f°C) is below freezing but conditions are too dry for significant frost (dew point %.1f°C)",
            surfaceTemp, dewPoint
        )
    end

    return result
```

[Refrence](https://www.weather.gov/source/zhu/ZHU_Training_Page/fog_stuff/Dew_Frost/Dew_Frost.htm)
[Reference, sida 39](https://www.diva-portal.org/smash/get/diva2:673365/FULLTEXT01.pdf)

## Output Topics

The edge-app publishes to two topics (replace `%s` with device EUI):

Dew point: `obj/lora/%s/dew_point` \
Frost precipitation: `obj/lora/%s/frost_precipitation`

## Example Notification

What is included in the notification that can be used in the template:

- **device_name** = device name
- **device_id** = lynx device id
- **device_eui** = eui for device
- **humidity** = humidity
- **air_temperature** = air temperature
- **surface_temperature** = surface temperature
- **dew_point** = dew point
- **value** = frost precipitation payload value
- **msg** = frost precipitation payload message
- **timestamp** = timestamp for the measurement

You can use this as template for notification:

```go
Risk för frostutfällning! - {{with toTime .payload.timestamp}}{{.Format "2006-01-02 15:04:05"}}{{end}}

Enhet: {{.payload.device_name}}
Installation:  {{.installation.Name}}
Organisation: {{.organization.Name}}
https://prod.iotjonkopingslan.se/installations/{{.installation.ID}}/devices/edit/{{.payload.device_id}}

Mätdata 
- Daggpunkt: {{.payload.dew_point}}°C
- Luft-temperature: {{.payload.air_temperature}}°C
- Yt-temperatur: {{.payload.surface_temperature}}°C
- Luftfuktighet: {{.payload.humidity}}

Statusmeddelande:
{{.payload.msg}}

Se mer information här:  
https://prod.iotjonkopingslan.se/grafana-pub/d/c08c7e53-3637-498d-82e9-9cfd74f4ca67/sno-och-halkbekampning-lansgemensam?orgId=1&from=now-12h&to=now&timezone=browser&var-installation={{.installation.ID}}&var-eui={{.payload.device_eui}}&refresh=1m
```
