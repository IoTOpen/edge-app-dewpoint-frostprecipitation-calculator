# edge-app-dewpoint-frostprecipitation-calculator
edge app to calculate dewpoint and frost precipitation using data from DL-WRM2.


Dewpoint is calcualted using Magnus formula:

γ = ((17.27 * T) / (237.7 + T)) + ln(RH/100)
Td = (237.7 * γ) / (17.27 - γ)

Where:
T = Air temperature in °C
RH = Relative humidity in %
Td = Dew point temperature in °C

## Output Topics
The system publishes to two topics (replace %s with device EUI):

obj/lora/%s/dew_point - Dew point temperature
obj/lora/%s/frost_precipitation - Frost precipitation 