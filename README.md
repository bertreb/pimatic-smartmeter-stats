pimatic-smartmeter-stats
===================

Creating statistics from smartmeter values. This plugin reads any smartmeter value that changes over time. The values are showing the change of the value over the last hour, day, week or month. 

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
  "input": "<name>", // The generated name for the input value (is result of expression)
  "expression": "....." // The input variable or expression string
  "unit": "" // The unit for the values, examples kWh, m3, etc
  "statistics": ["hour", "day", "week", "month"] // The timescale and name of the resulting variable
  "test": boolean 
}
```

Configuration
-------------

Create a new SmartmeterStats device.

The initial device exposes only the "input" variable ${id}.{input}. This is the result of the expression and will be updated if one of the expression variables changes. 
The available statistics variables are:
- hour - the change of the expression input value in the last hour
- day - the change of the input value in the last day (00:00-23:59)
- week - the change of the input value in the last week (monday-sunday)
- month - the change of the input value in the last month

On init of the plugin the first readout is based on the time left till the next full hour, day(00:00), week (monday) or month (1ste).

The plugin is in development. Please backup Pimatic before you are using it!