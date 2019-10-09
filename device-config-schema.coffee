module.exports = {
  title: "pimatic-smartmeter-stats device config schemas"
  SmartmeterStatsDevice: {
    title: "Smartmeter config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      input:
        type: "string"
        description: "The name of the input attribute."
        required: true
      expression:
        description: "
          The expression to use to get the input value. I can be a variable name ($myVar),
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
          enum: ["hour", "day", "week", "month"]
      test:
        type: "boolean"
        description: "enable to get faster timing for testing (Hour=10 sec, Day=1 minute, Week=3 minutes, Month=10 minutes)"
        default: false
  }
}
  