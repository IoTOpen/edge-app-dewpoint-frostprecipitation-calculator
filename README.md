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

The logic for calculating frost precipitation uses the calculated dew point and surface temperature.

If the surface temperature is below the threshold (set 2 degrees higher than the freezing point to compensate for sensor error margin) and the difference between air temperature and dew point is within the set margin*, we assume there is a risk for frost. Otherwise, we assume there is no risk or it is very unlikely.

#### Code

0 = No frost\
1 = Frost is possible

```lua
      local result = {
        isFrostPossible = 0,
        reason = ""
    }

    local surfaceThreshold = 2.0 -- Frost threshold temperature (°C), compensate for sensor error margin
     local moistureThreshold = 4.0 -- Moisture availability threshold (°C),larger span for variation is sensors (RH ~70-100%)
    -- No frost risk if surface temperature is well above freezing
    if surfaceTemp > surfaceThreshold then
        result.reason = string.format(
            "Ingen uträknad risk för frost! Marktemperatur: %.1f°C är över tröskelvärdet: %.1f°C",
            surfaceTemp, surfaceThreshold
        )
        return result
    end

    -- Calculate moisture availability (difference between air temperature and dew point)
    local moistureAvailability = airTemp - dewPoint

    -- High risk: freezing + high humidity/close dew point
    if moistureAvailability < moistureThreshold then
        result.isFrostPossible = 1
        result.reason = string.format(
            "Risk för frost! Marktemperatur: (%.1f°C), Lufttemperatur: (%.1f°C), Daggpunkt (%.1f°C)",
            surfaceTemp, airTemp, dewPoint
        )
    else
        result.reason = string.format(
            "Ingen uträknad risk för frost! Marktemperatur: (%.1f°C), Lufttemperatur: (%.1f°C), Daggpunkt: (%.1f°C)",
            surfaceTemp, airTemp, dewPoint
        )
    end

    return result
```

\* We assume there is not enough moisture in the air when the difference between air temperature and dew point is to large, first reference.

[Refrence 1](https://www.weather.gov/source/zhu/ZHU_Training_Page/fog_stuff/Dew_Frost/Dew_Frost.htm)
[Reference 2, sida 39](https://www.diva-portal.org/smash/get/diva2:673365/FULLTEXT01.pdf)

## Frost ok intertia

The app includes a frost inertia feature to prevent rapid changes in frost status. This helps avoid false alarms and provides more stable readings by requiring consistent conditions over time before changing the frost precipitation status.
Conditions that are needed to be met are 3 ok in a row or that no ok came in during 45min from the last one.

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
