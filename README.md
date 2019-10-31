pimatic-smartmeter-stats
===================

Creating statistics from smartmeter values. This plugin contains 2 devices.
- The SmartmeterDegreedaysDevice uses outdoor temperature and windspeed data and heating energy consumption data (gas, etc) to create degreeday and efficiency values. They are a measure of your heating energy effciency. You can use them to compare your own energy efficiency and what for example isolation measures or lowering the indoor temparture will do.
- The SmartmeterStatsDevice reads any smartmeter value that increases over time. The generated values are showing the increase of the value over the last hour, day, week or month.

Installation
------------
To enable the smartmeter-stats plugin add this to the plugins section via the GUI or add it in the config.json file.

```
...
{
  "plugin": "Smartmeter-stats"
}
...
```

Degreedays
------------
Degreeday is a measure for heating and cooling. The so called Heating degreedays are typical indicators of household energy consumption for space heating. This plugin works only for heating degreedays.
The degreeday calculation used in the plugin is based on:
- BaseTemprature: is the outdoor reference temperature for degreeday days, the default is 18°C, and can be changed.
- Temperature: the outdoor and indoor temperature
- Windspeed: the windspeed in m/s
- Month of the year (factor depending on month)

The used formulae for degreedays is:
     degreedays = month-factor * (BaseTemperature - ( Temperature - 2/3 x windspeed ))

Only when the result is above 0 the calculated degreeday value is used, otherwise its 0.
The degreedays are calculated per hour and added up to the daily value. So the day value is based on 24 hour values.

The used formulae for efficiency is:
    efficiency = energy consumption / degreedays

Only when the degreedays are above 0 and energy was consumed, a efficiency factor is calculated, otherwise its 0
The efficiency is calculated per hour. The daily efficiency is the sum of hour values.

To use the degreedays device you need to have the following data variables available in Pimatic:
- Realtime outdoor temperature
- Realtime energy total value (not the current usage but the absolute total usage value).

If available the following variables will increase the quality of the data:
- Realtime windspeed
- indoor temperature of the main heated mainroom (not yet used)

Realtime means that the value should be updated at least once an hour.


Degreedays device
-----------------
When the plugin is installed (including restart) a SmartmeterDegreedays device can be added. Below the settings with the default values.

```
{
  "id": "<smartmeter-degreedays-id>",
  "class": "SmartmeterDegreedaysDevice",
  "temperature": "<name>", // The variable that hold the outdoor temperature
  "energy": "<variable>" // The variable that holds the actual total energy value. This can be gas or electricity.
  "wind": <variable> // The variable that hold the windspeed value (optional)
  "temperatureIn": "<variable>", // The variable that hold the indoor temperature (optional)
  "baseTemperature": 18 // The temperature the heating degreedays calculation is based upon
  "energyUnit": "" // The energy unit in the frontend
  "energyLabel": "" // A custom label for energy to use in the frontend
  "energyAcronym": "" // Acronym for energy to show as value label in the frontend
  "log": none | hour | day // Select to have a none, hourly or daily log of the Degreeday values
  "test": boolean // Enable to speedup the daily proces to minutes (for testing)
}
```

Configuration

The statistics are calculated on a daily bases starting at midnight. The statistics variables are available per hour or per day.

Hourly (update at start of every hour):
- temperatureHour - last hour average outdoor temperature
- temperatureInHour - last hour average outdoor temperature (optional)
- energyHour - last hour energy consumption
- windspeedHour - lat hour average windspeed (optional)
- degreedaysHour - last hour degreeday values (00:00-23:59)
- efficiencyHour - last hour efficiency factor: (last hour energy consumption) / last hur degreedays

Daily (update at start of day):
- temperatureDay - yesterdays average outdoor temperature
- temperatureInDay - yesterdays average outdoor temperature (optional)
- energyDay - yesterdays energy consumption
- windspeedDay - yesterdays average windspeed (optional)
- degreedaysDay - yesterdays degreeday values (00:00-23:59)
- efficiencyDay - yesterdays efficiency factor: (energy consumption) / degreeday

The plugin needs max 2 days to get aligned. On init of the plugin during the first day the status is 'init'. During the first full day the status is 'processing 1st day'. And starting the 2nd day the status is the date of yesterday and the values are from yesterday and accurate.

For longterm usage of the values, a log can be enabled. The log will add at the start of every hour or day (selected in config) the values for that passed hour or day. To make the log standalone usable, a timestamp is added.

The hourly/daily data is added as a JSON record. The logfile is made compact and readable with one daily data row per day. The logfile is available in a directory called 'smartmeter-data', located in the pimatic home directory of the computer running Pimatic (mostly ../pimatic-app). The log will have the name 'device-name'-data.json.

You can reset the device and set the values to 0 with the command reset 'device name'. This command can be used in rules, so you can create a button to reset the values or reset on any other condition/event.

Stats device
------------
When the plugin is installed (including restart) a SmartmeterStats device can be added. Below the settings with the default values.

```
{
  "id": "<smartmeter-stats-id>",
  "class": "SmartmeterStatsDevice",
  "input": "<name>", // The generated name for the input value (is result of expression)
  "expression": "....." // The input variable or expression string
  "unit": "" // The unit for the values, examples kWh, m3, etc
  "statistics": ["hour", "day", "week", "month"] // The timescale and name of the resulting variable
  "log": none | hour | day // Select to have a none, hourly or daily log of the Stats values
  "test": boolean
}
```

Configuration

The initial device exposes no variables in the GUI. You can add them in the device configuration.
The available statistics variables are:
- actual - the actual input value. This is the result of the expression and will be updated if one of the expression variables changes.
- hour - the change of the expression input value in the last hour
- day - the change of the input value in the last day (00:00-23:59)
- week - the change of the input value in the last week (monday-sunday)
- month - the change of the input value in the last month

On init of the plugin the first readout is based on the time left till the next full hour, day(00:00), week (monday) or month (1ste).

For longterm usage of the values, a log can be enabled. The log will add at the start of every hour or day (selected in config) the values for that passed hour or day. To make the log standalone usable, a timestamp is added.

The hourly/daily data is added as a JSON record. The logfile is made compact and readable with one daily data row per day. The logfile is available in a directory called 'smartmeter-data', located in the pimatic home directory of the computer running Pimatic (mostly ../pimatic-app). The log will have the name 'device-name'-data.json.

You can reset the device and set the values to 0 with the command reset 'device name'. This command can be used in rules, so you can create a button to reset the values or reset on any other condition/event.

---------

The plugin is in development. Please backup Pimatic before you are using it!
