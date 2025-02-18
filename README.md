# edge-app-dewpoint-frostprecipitation-calculator
Edge-app that calculate dew point and frost precipitation.

Users choose for what devices calculations should be made and what functions to be used for calculations. <strong>If not necessary input data is included the calculation wont work.</strong> When setting up the app, functions it doesn't think are needed will be filtered out. If this app is used with another sensors then Decentlab or Elsys this might need to be updated.
Edge-app also can send notification when frost precipitation is happening (value is 1)

#### Necessary Input sensor data:
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