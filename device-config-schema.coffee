module.exports = {
  title: "pimatic-smartmeter-stats device config schemas"
  SmartmeterStatsDevice: {
    title: "Smartmeter config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      expression:
        description: "
          The expression to use to get the actual input value. I can be a variable name ($myVar),
          a calculation ($myVar + 10) or a string interpolation (\"Test: {$myVar}!\")
          "
        type: "string"
        required: true
      unit:
        type: "string"
        description: "The attribute unit to be displayed. The default unit will be displayed if not set."
        required: false
        default: ""
      statistics:
        description: "Smartmeter statistics timebase that will be exposed in the device. Day starts at 00:00 and Week start on monday 00:00"
        type: "array"
        default: []
        format: "table"
        items:
          enum: ["actual", "actualday", "minute", "hour", "day", "week", "month"]
      log:
        description: "enable to get daily data (in JSON format) in a logfile"
        type: "boolean"
        default: false
      test:
        type: "boolean"
        description: "enable to get faster timing for testing (Hour=10 sec, Day=1 minute, Week=3 minutes, Month=10 minutes)"
        default: false
  }
  SmartmeterDegreedaysDevice: {
    title: "Smartmeter heating options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      temperature:
        type: "string"
        description: "the variable that has the actual outdoor temperature"
        required: true
        unit: "°C"
      energy:
        description: "the variable that holds the actual total energy value. This can be gas or electricity."
        type: "string"
        required: true
      windspeed:
        description: "the variable that holds the actual windspeed in m/s."
        type: "string"
        required: false
      temperatureIn:
        type: "string"
        description: "The variable that has the actual indoor temperature."
        required: false
        unit: ""
      baseTemperature:
        description: "The temperature the heating degreedays calculation is based upon"
        type: "number"
        unit: "°C"
        required: true
        default: 18.0
      energyUnit:
        description: "The energy unit in the frontend"
        type: "string"
        default: "m3"
        required: false
      energyLabel:
        description: "A custom label to use in the frontend."
        type: "string"
        default: "gas"
        required: false
      energyAcronym:
        description: "Acronym to show as value label in the frontend"
        type: "string"
        default: "gas"
        required: false
      stats:
        description: "Smartmeter degreedevice variables that will be exposed in the Gui."
        type: "array"
        default: []
        format: "table"
        items:
          enum: [
            "status",
            "temperature", "temperatureIn", "windspeed", "energy", "degreedays", "efficiency", "r2", "baseTemp"
          ]
      log:
        description: "Select to get none or daily data (in JSON format) in a logfile. Logfile is used to get an adaptive baseTemperature."
        type: "boolean"
        default: true
      test:
        type: "boolean"
        description: "Enable to get faster timing for testing (Hour=10 sec, Day=30 seconds, Week=2 minutes, Month=5 minutes)"
        default: false
  }
}
