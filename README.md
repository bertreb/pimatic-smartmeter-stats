pimatic-smartmeter-stats
===================

Creating energy statistics from smartmeter values. This plugin reads an energy consumption or production values that increases over time. The values are showing the delta of the value over the last hour, day, week or month.

Installation
------------
To enable the smartmeter plugin add this to the plugins section via the GUI or add it in the config.json file.

```
...
{
  "plugin": "Smartmeter-stats"
}
...
```

After restart of Pimatic the SmartmeterObis device can be added. Below the settings with the default values.

```
{
  "id": "smartmeter-stats",
  "class": "SmartmeterStatsDevice",
  "input": "<name>", // the generated name for the used input value (is result of expression)
  "expression": "....." // The used input variable or expression string
  "unit": "" // the used unit for the values, examples kWh, m3, etc
  "statistics": ["hour", "day", "week", "month"] // the used timeschale and name of the resulting variable
  "test": boolean 
}
```

Configuration
-------------

Create a new SmartmeterStats device.

The initial device exposes only the "input" variable $<id>.<input>. This is the result of the expression and will be updated if one of the expression variables changes. 
The available statistics variables are:
- hour - the increase of the input value in the last hour; $<id>.hour
- day - the increase of the input value in the last day; $<id>.day
- week - the increase of the input value in the last week; $<id>.week
- month - the increase of the input value in the last month; $<id>.month

On init of the plugin the first readout is based on the time left till the next full hour, day(00:00), week (monday) or month (1ste).

The plugin is in development. Please backup Pimatic before you are using it!