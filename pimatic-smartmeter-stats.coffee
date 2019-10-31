module.exports = (env) ->
  Promise = env.require 'bluebird'
  assert = env.require 'cassert'
  types = env.require('decl-api').types
  fs = env.require('fs')
  M = env.matcher
  Moment = require 'moment-timezone'
  path = require 'path'
  _ = env.require('lodash')


  CronJob = env.CronJob or require('cron').CronJob

  # cron definitions
  everyHour = "0 0 * * * *"
  everyDay = "0 1 0 * * *" # at midnight at 00:01
  everyWeek = "0 2 0 * * 1" # monday at 00:02
  everyMonth = "0 3 0 1 * *" # first day of the month at 00:03

  # cron test definitions
  everyHourTest = "0,30 * * * * *" # every 30 seconds
  everyDayTest = "2 */2 * * * *" # every 2 minutes + 2 seconds
  everyWeekTest = "20 */3 * * * *" # every 3 minutes and 5 seconds
  everyMonthTest = "30 */5 * * * *" #every 5 minutes and 10 seconds

  class SmartmeterStatsPlugin extends env.plugins.Plugin
    init: (app, @framework, @config) =>

      @dirPath = path.resolve @framework.maindir, '../../smartmeter-data'
      if !fs.existsSync(@dirPath)
        fs.mkdirSync(@dirPath)

      deviceConfigDef = require('./device-config-schema')
      @framework.deviceManager.registerDeviceClass('SmartmeterStatsDevice', {
        configDef: deviceConfigDef.SmartmeterStatsDevice,
        createCallback: (config, lastState) => new SmartmeterStatsDevice(config, lastState, @framework, @dirPath)
      })
      @framework.deviceManager.registerDeviceClass('SmartmeterDegreedaysDevice', {
        configDef: deviceConfigDef.SmartmeterDegreedaysDevice,
        createCallback: (config, lastState) => new SmartmeterDegreedaysDevice(config, lastState, @framework, @dirPath)
      })

      @framework.ruleManager.addActionProvider(new SmartmeterStatsActionProvider @framework, @config)
      @framework.ruleManager.addActionProvider(new SmartmeterDegreedaysActionProvider @framework, @config)


  plugin = new SmartmeterStatsPlugin

  class SmartmeterStatsDevice extends env.devices.Device

    actions:
      resetSmartmeterStats:
        description: "Resets the stats attribute values"

    constructor: (@config, lastState, @framework, @dirPath) ->

      @id = @config.id
      @name = @config.name

      @expression = @config.expression
      @unit = if @config.unit? then @config.unit else ""
      @_vars = @framework.variableManager
      @_exprChangeListeners = []
      @logging = if @config.log? then @config.log else "none"
      @statsLogFullFilename = path.join(@dirPath, './' + @id + '-data.json')
      @test = @config.test

      @attributeList = ["actual", "hour", "lasthour", "day", "lastday", "week", "lastweek", "month", "lastmonth"]
      @attributes = {}
      @attributeValues = {}

      for _attr in @attributeList
        do (_attr) =>
          @attributes[_attr] =
            description: _attr + " value"
            type: types.number
            unit: @unit
            acronym: _attr
            hidden: true
            default: 0.0
          @attributeValues[_attr] = 0.0
          @_createGetter(_attr, =>
              return Promise.resolve @attributeValues[_attr]
          )

      @updateJobs = []

      @attributeValues.actual = lastState?.actual?.value or 0.0
      @attributeValues.hour = lastState?.hour?.value or 0.0
      @attributeValues.lasthour = lastState?.lasthour?.value or 0.0
      @attributeValues.day = lastState?.day?.value or 0.0
      @attributeValues.lastday = lastState?.lastday?.value or 0.0
      @attributeValues.week = lastState?.week?.value or 0.0
      @attributeValues.lastweek = lastState?.lastweek?.value or 0.0
      @attributeValues.month = lastState?.month?.value or 0.0
      @attributeValues.lastmonth = lastState?.lastmonth?.value or 0.0
      @init = true

      @expression = @expression.replace /(^[a-z])|([A-Z])/g, ((match, p1, p2, offset) =>
              (if offset>0 then " " else "") + match.toUpperCase())

      parseExprAndAddListener = ( () =>
        @_info = @_vars.parseVariableExpression(@expression)
        @_vars.notifyOnChange(@_info.tokens, onChangedVar)
        @_exprChangeListeners.push onChangedVar
      )

      evaluateExpr = ( (varsInEvaluation) =>
        if @expression.type is "number"
          unless @expression.unit? and @expression.unit.length > 0
            @expression.unit = @_vars.inferUnitOfExpression(@_info.tokens)
        switch @_info.datatype
          when "numeric" then @_vars.evaluateNumericExpression(@_info.tokens, varsInEvaluation)
          when "string" then @_vars.evaluateStringExpression(@_info.tokens, varsInEvaluation)
          else assert false
      )

      onChangedVar = ( (changedVar) =>
        evaluateExpr().then( (val) =>
          @emit "actual", val
          @attributeValues.actual = val
          if @init == true # set all lastValues to the current input value
            @attributeValues.lasthour = val if @attributeValues.lasthour is 0
            @attributeValues.lastday = val  if @attributeValues.lastday is 0
            @attributeValues.lastweek = val if @attributeValues.lastweek is 0
            @attributeValues.lastmonth = val if @attributeValues.lastmonth is 0
            @init = false
        )
      )

      getValue = ( (varsInEvaluation) =>
        # wait till variableManager is ready
        return @_vars.waitForInit().then( =>
          unless @_info?
            parseExprAndAddListener()
          return evaluateExpr(varsInEvaluation)
        ).then( (val) =>
          if val isnt @_attributesMeta["actual"].value
            @emit "actual", val
          return val
        )
      )
      @_createGetter("actual", getValue)

      # create CronJobs for all the required timers for hour, day, week and month
      for attributeName in @config.statistics
        do (attributeName) =>
          @attributes[attributeName].hidden = false
          @attributes[attributeName].unit = @unit
          switch attributeName
            when "hour"
              @updateJobs.push new CronJob
                cronTime:  if @config.test then everyHourTest else everyHour
                onTick: =>
                  @attributeValues.hour = @attributeValues.actual - @attributeValues.lasthour
                  @attributeValues.lasthour = @attributeValues.actual
                  @emit "hour", @attributeValues.hour
                  @emit "lasthour", @attributeValues.lasthour
                  if @logging is "hour"
                    @_log(@attributeValues.hour, @attributeValues.day, @attributeValues.week, @attributeValues.month, @unit)
            when "day"
              @updateJobs.push new CronJob
                cronTime: if @config.test then everyDayTest else everyDay
                onTick: =>
                  @attributeValues.day = @attributeValues.actual - @attributeValues.lastday
                  @attributeValues.lastday = @attributeValues.actual
                  @emit "day", @attributeValues.day
                  @emit "lastday", @attributeValues.lastday
                  if @logging is "day"
                    @_log(@attributeValues.hour, @attributeValues.day, @attributeValues.week, @attributeValues.month, @unit)
            when "week"
              @updateJobs.push new CronJob
                cronTime: if @config.test then everyWeekTest else everyWeek
                onTick: =>
                  @attributeValues.week = @attributeValues.actual - @attributeValues.lastweek
                  @attributeValues.lastweek = @attributeValues.actual
                  @emit "week", @attributeValues.week
                  @emit "lastweek", @attributeValues.lastweek
            when "month"
              @updateJobs.push new CronJob
                cronTime: if @config.test then everyMonthTest else everyMonth
                onTick: =>
                  @attributeValues.month = @attributeValues.actual - @attributeValues.lastmonth
                  @attributeValues.lastmonth = @attributeValues.actual
                  @emit "month", @attributeValues.month
                  @emit "lastmonth", @attributeValues.lastmonth
      if @updateJobs?
        for jb in @updateJobs
          jb.start()

      super()

    _log: (hour, day, week, month, unit) ->
      d = new Date()
      moment = Moment(d).subtract(1, 'days')
      timestampDatetime = moment.format("YYYY-MM-DD HH:mm:ss")
      if fs.existsSync(@statsLogFullFilename)
        data = fs.readFileSync(@statsLogFullFilename, 'utf8')
        statsData = JSON.parse(data)
      else
        statsData = []
      try
        update =
          id: @id
          timestamp: timestampDatetime
          hour: Number hour.toFixed(1)
          day: Number day.toFixed(1)
          week: Number week.toFixed(1)
          month: Number month.toFixed(1)
          unit: unit
        statsData.push update
        #data is saved once a day
        if @test then env.logger.info "'" + @id + "' data written to log"
        fs.writeFileSync(@statsLogFullFilename, @_prettyCompactJSON(statsData))
      catch e
        env.logger.error e.message
        env.logger.error "log not writen"
        return

    _prettyCompactJSON: (data) ->
      for v, i in data
        if i is 0 then str = "[\n\r"
        str += " " + JSON.stringify(v)
        if i isnt data.length-1 then str += ",\n\r" else str += "\n\r]"
      return str

    resetSmartmeterStats: () ->
      for _attrName of @attributes
        do (_attrName) =>
          @defaultVal = 0
          @defaultVal = @attributes[_attrName].default
          @attributeValues[_attrName] = @defaultVal
          @emit _attrName, @defaultVal
      Promise.resolve()

    destroy: ->
      @_vars.cancelNotifyOnChange(cl) for cl in @_exprChangeListeners
      if @updateJobs?
        jb.stop() for jb in @updateJobs
      super()


  class SmartmeterDegreedaysDevice extends env.devices.Device

    actions:
      resetSmartmeterDegreedays:
        description: "Resets the degreedays attribute values"
    attributes:
      status:
        description: "Status of the data processing"
        type: "string"
        unit: ''
        acronym: 'data'
        default: "init"
      statusLevel:
        description: "status of data processing"
        type: types.number
        acronym: 'statusLevel'
        default: 1
        hidden: true
      temperatureHour:
        description: "Last hour average outdoor temperature"
        type: types.number
        unit: '°C'
        acronym: 'ToH'
        default: 0.0
        displayFormat: "fixed, decimals:1"
      temperatureInHour:
        description: "Last hour average indoor temperature"
        type: types.number
        unit: '°C'
        acronym: 'TiH'
        default: null
        displayFormat: "fixed, decimals:1"
        hidden: true
      windspeedHour:
        description: "Last hour average windspeed"
        type: types.number
        unit: 'm/s'
        acronym: 'Wi-H'
        default: 0.0
        displayFormat: "fixed, decimals:1"
        hidden: true
      energyHour:
        description: "Last hour energy usage"
        type: types.number
        unit: ''
        default: 0.0
        acronym: 'E-H'
        displayFormat: "fixed, decimals:1"
      degreedaysHour:
        description: "Last hour degreedays"
        type: types.number
        unit: ''
        default: 0.0
        acronym: '°dayH'
        displayFormat: "fixed, decimals:1"
      efficiencyHour:
        description: "Last hour efficiency ratio (e-index)"
        type: types.number
        unit: 'E/°day'
        default: 0.0
        acronym: 'e-indexH'
        displayFormat: "fixed, decimals:1"
      temperatureDay:
        description: "Yesterdays average outdoor temperature"
        type: types.number
        unit: '°C'
        acronym: 'ToD'
        default: 0.0
        displayFormat: "fixed, decimals:1"
      temperatureInDay:
        description: "Yesterdays average indoor temperature"
        type: types.number
        unit: '°C'
        acronym: 'TiD'
        default: null
        displayFormat: "fixed, decimals:1"
        hidden: true
      windspeedDay:
        description: "Yesterdays average windspeed"
        type: types.number
        unit: 'm/s'
        acronym: 'W-D'
        default: 0.0
        displayFormat: "fixed, decimals:1"
        hidden: true
      energyDay:
        description: "Yesterdays energy usage"
        type: types.number
        unit: ''
        default: 0.0
        acronym: 'E-D'
        displayFormat: "fixed, decimals:1"
      degreedaysDay:
        description: "Yesterdays degreedays"
        type: types.number
        unit: ''
        default: 0.0
        acronym: '°dayD'
        displayFormat: "fixed, decimals:1"
      efficiencyDay:
        description: "Yesterdays efficiency ratio (e-index)"
        type: types.number
        unit: 'E/°day'
        default: 0.0
        acronym: 'e-indexD'
        displayFormat: "fixed, decimals:1"

    constructor: (@config, lastState, @framework, @dirPath) ->
      @id = @config.id
      @name = @config.name
      @test = @config.test
      @vars = if @config.stats? then @config.stats else null#.properties
      @temperatureName = if @config.temperature[0] == "$" then @config.temperature.substr(1) else @config.temperature
      @temperatureInName = if @config.temperatureIn? then @config.temperatureIn else ""
      @energyName = if @config.energy[0] == "$" then @config.energy.substr(1) else @config.energy
      @baseTemperature = if @config.baseTemperature? then @config.baseTemperature else 18.0
      @windspeedName =  if @config.windspeed? then @config.windspeed else ""
      if @temperatureInName[0]== "$" then @temperatureInName = @temperatureInName.substr(1)
      if @windspeedName[0]== "$" then @windspeedName = @windspeedName.substr(1)
      for _attrName in ["energyHour", "energyDay"]
        @attributes[_attrName].unit = if @config.energyUnit? then @config.energyUnit else ""

      @logging = if @config.log? then @config.log else "none"
      @ddLogFullFilename = path.join(@dirPath, './' + @id + '-data.json')

      @tempSampler = new Sampler()
      @tempInSampler = new Sampler()
      @windspeedSampler = new Sampler()
      @degreedaysSampler = new Sampler()

      @states = ["off", "init", "processing 1st day", "yesterday"]

      @attributeValues = {}

      for _attr of @attributes
        do (_attr) =>
          env.logger.info _attr
          @attributeValues[_attr] = null
          @_createGetter(_attr, =>
              return Promise.resolve @attributeValues[_attr]
          )

      @attributeValues.temperatureHour = lastState?.temperatureHour?.value or 0.0
      @attributeValues.temperatureDay = lastState?.temperatureDay?.value or 0.0
      @attributeValues.temperatureInHour = lastState?.temperatureInHour?.value or 0.0
      @attributeValues.temperatureInDay = lastState?.temperatureInDay?.value or 0.0
      @attributeValues.windspeedHour = lastState?.windspeedHour?.value or 0.0
      @attributeValues.windspeedDay = lastState?.windspeedDay?.value or 0.0
      @attributeValues.energyHour = lastState?.energyHour?.value or 0.0
      @attributeValues.energyDay = lastState?.energyDay?.value or 0.0
      @attributeValues.lastEnergyHour = lastState?.lastEnergyHour?.value or 0.0
      @attributeValues.lastEnergyDay = lastState?.lastEnergyDay?.value or 0.0
      @attributeValues.degreedaysHour = lastState?.degreedaysHour?.value or 0.0
      @attributeValues.degreedaysDay = lastState?.degreedaysDay?.value or 0.0
      @attributeValues.efficiencyHour = lastState?.efficiencyHour?.value or 0.0
      @attributeValues.efficiencyDay = lastState?.efficiencyDay?.value or 0.0
      @attributeValues.statusLevel = lastState?.statusLevel?.value or 1
      @attributeValues.status = lastState?.status?.value or ""

      @updateJobs2 = []

      unless @framework.variableManager.getVariableByName(@temperatureName)?
        throw new Error("'" + @temperatureName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@temperatureInName)? or @temperatureInName is ""
        throw new Error("'" + @temperatureInName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@windspeedName)? or @windspeedName is ""
        throw new Error("'" + @windspeedName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@energyName)?
        throw new Error("'" + @energyName + "' does not excist")

      @updateJobs2.push new CronJob
        cronTime: if @test then everyHourTest else everyHour
        onTick: =>
          if @test then env.logger.info "HourTest update"
          _temp = Number @framework.variableManager.getVariableByName(@temperatureName).value
          _tempIn = if @temperatureInName isnt "" then Number @framework.variableManager.getVariableByName(@temperatureInName).value else _tempIn = null
          _windspeed = if @windspeedName isnt "" then Number @framework.variableManager.getVariableByName(@windspeedName).value else _windspeed = null
          _energy = Number @framework.variableManager.getVariableByName(@energyName).value

          if @attributeValues.lastEnergyHour == null then @attributeValues.lastEnergyHour = _energy
          if @attributeValues.lastEnergyDay == null then @attributeValues.lastEnergyDay = _energy

          @attributeValues.temperatureHour = _temp  # average value
          @attributeValues.temperatureInHour = _tempIn   # average value
          @attributeValues.windspeedHour = _windspeed  # average value
          @attributeValues.energyHour = _energy - @attributeValues.lastEnergyHour   # 1 hour energy comsumption
          @attributeValues.lastEnergyHour = _energy

          #add hour values to samlers for day calculation
          @tempSampler.addSample @attributeValues.temperatureHour
          @tempInSampler.addSample @attributeValues.temperatureInHour
          @windspeedSampler.addSample @attributeValues.windspeedHour
          _dd = @_calcDegreeday(@baseTemperature, _temp, _windspeed) # calc degreedays Hour for current temperature and wind
          @degreedaysSampler.addSample _dd
          @attributeValues.efficiencyHour = if _dd > 0 then (@attributeValues.energyHour/_dd) else 0
          @attributeValues.degreedaysHour = _dd

          if @logging is "hour"
            @framework.variableManager.waitForInit().then( =>
              for _attrName of @attributes
                do (_attrName) =>
                  @emit _attrName, @attributeValues[_attrName]
            )
            @_log(
              @attributeValues.temperatureHour,
              @attributeValues.temperatureInHour,
              @attributeValues.windspeedHour,
              @attributeValues.energyHour,
              @attributeValues.degreedaysHour,
              @attributeValues.efficiencyHour
            )

      @updateJobs2.push new CronJob
        cronTime: if @test then everyDayTest else everyDay
        onTick: =>
          if @test then env.logger.info "DayTest update"
          @attributeValues.statusLevel +=1 unless @attributeValues.statusLevel >= 3
          if @attributeValues.statusLevel == 3
            moment = Moment(new Date())
            timestampDatetime = moment.format("YYYY-MM-DD HH:mm")
            @states[3] = timestampDatetime
          @attributeValues.status = @states[@attributeValues.statusLevel]

          # calculate full day values
          _energy = Number @framework.variableManager.getVariableByName(@energyName).value # the actual energy value
          @attributeValues.temperatureDay = @tempSampler.getAverage true
          @attributeValues.temperatureInDay = @tempInSampler.getAverage true
          @attributeValues.windspeedDay = @windspeedSampler.getAverage true
          @attributeValues.energyDay = _energy - @attributeValues.lastEnergyDay
          @attributeValues.degreedaysDay = @degreedaysSampler.getAverage true
          @attributeValues.efficiencyDay = if @attributeValues.degreedaysDay > 0 then (@attributeValues.energyDay / @attributeValues.degreedaysDay) else 0

          @attributeValues.lastEnergyDay = _energy # for usage per day

          for _attrName of @attributes
            do (_attrName) =>
              @emit _attrName, @attributeValues[_attrName]

          if @logging is "day"
            @_log(
              @attributeValues.temperatureDay,
              @attributeValues.temperatureInDay,
              @attributeValues.windspeedDay,
              @attributeValues.energyDay,
              @attributeValues.degreedaysDay,
              @attributeValues.efficiencyDay
            )

      if @updateJobs2?
        for jb2 in @updateJobs2
          jb2.start()

      super()

    _calcDegreeday: (base, temp, wind) ->
      currentMonth = (new Date).getMonth() # 0=january
      factor = 1.0 # April and October
      factor = 0.8 if currentMonth >= 4 && currentMonth <= 8 # May till September
      factor = 1.1 if currentMonth <=1 || currentMonth >= 10 # November till March
      degreeday = factor * ( base - temp + (2/3) * wind)
      degreeday = 0 unless degreeday > 0
      return Number degreeday

    resetSmartmeterDegreedays: () ->
      for _attrName of @attributes
      	do (_attrName) =>
          @defaultVal = 0
          switch _attrName
            when "lastEnergyHour"
              @defaultVal = @attributeValues.lastEnergyHour
            when "lastEnergyDay"
              @defaultVal = @attributeValues.lastEnergyDay
            else
            	@defaultVal = @attributes[_attrName].default
            	@attributeValues[_attrName] = @defaultVal
        	@emit _attrName, @defaultVal
      Promise.resolve()

    _log: (tempOut, tempIn, wind, energy, ddays, eff) ->
      d = new Date()
      moment = Moment(d).subtract(1, 'days')
      timestampDatetime = moment.format("YYYY-MM-DD HH:mm:ss")
      if fs.existsSync(@ddLogFullFilename)
        data = fs.readFileSync(@ddLogFullFilename, 'utf8')
        degreedaysData = JSON.parse(data)
      else
        degreedaysData = []

      try
        update =
          id: @id
          timestamp: timestampDatetime
          temp_out: Number tempOut.toFixed(1)
          temp_in: if tempIn? then Number tempIn.toFixed(1) else null
          energy: Number energy.toFixed(2)
          windspeed: if wind? then  Number wind.toFixed(2) else null
          ddays: Number ddays.toFixed(2)
          eff: Number eff.toFixed(2)
        degreedaysData.push update
        #data is saved once a day
        if @test then env.logger.info "'" + @id + "' data written to log"
        fs.writeFileSync(@ddLogFullFilename, @_prettyCompactJSON(degreedaysData))
      catch e
        env.logger.error e.message
        env.logger.error "log not writen"
        return

    _prettyCompactJSON: (data) ->
      for v, i in data
        if i is 0 then str = "[\n\r"
        str += " " + JSON.stringify(v)
        if i isnt data.length-1 then str += ",\n\r" else str += "\n\r]"
      return str

    destroy: ->
      if @updateJobs2?
        jb2.stop() for jb2 in @updateJobs2
      super()

  class SmartmeterStatsActionProvider extends env.actions.ActionProvider
    constructor: (@framework) ->

    parseAction: (input, context) =>

      filterDevices = _(@framework.deviceManager.devices).values().filter(
        (device) => (
          device.hasAction("resetSmartmeterStats")
        )
      ).value()

      device = null
      action = null
      match = null

      m = M(input, context).match(['reset '], (m, a) =>
        m.matchDevice(filterDevices, (m, d) ->
          last = m.match(' smartmeterDegreedays', {optional: yes})
          if last.hadMatch()
            # Already had a match with another device?
            if device? and device.id isnt d.id
              context?.addError(""""#{input.trim()}" is ambiguous.""")
              return
            device = d
            action = a.trim()
            match = last.getFullMatch()
        )
      )

      if match?
        assert device?
        assert action in ['reset']
        assert typeof match is "string"
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new SmartmeterStatsActionHandler(device)
        }

        return null

  class SmartmeterStatsActionHandler extends env.actions.ActionHandler
    constructor: (@device) ->

    setup: ->
      @dependOnDevice(@device)
      super()

    # ### executeAction()
    executeAction: (simulate) =>
      return (
        if simulate
          Promise.resolve __("would reset %s", @device.name)
        else
          @device.resetSmartmeterStats().then( => __("reset %s", @device.name) )
      )
    # ### hasRestoreAction()
    hasRestoreAction: -> false

  class SmartmeterDegreedaysActionProvider extends env.actions.ActionProvider
    constructor: (@framework) ->

    parseAction: (input, context) =>

      filterDevices = _(@framework.deviceManager.devices).values().filter(
        (device) => (
          device.hasAction("resetSmartmeterDegreedays")
        )
      ).value()

      device = null
      action = null
      match = null

      m = M(input, context).match(['reset '], (m, a) =>
        m.matchDevice(filterDevices, (m, d) ->
          last = m.match(' smartmeterDegreedays', {optional: yes})
          if last.hadMatch()
            # Already had a match with another device?
            if device? and device.id isnt d.id
              context?.addError(""""#{input.trim()}" is ambiguous.""")
              return
            device = d
            action = a.trim()
            match = last.getFullMatch()
        )
      )

      if match?
        assert device?
        assert action in ['reset']
        assert typeof match is "string"
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new SmartmeterDegreedaysActionHandler(device)
        }

        return null

  class SmartmeterDegreedaysActionHandler extends env.actions.ActionHandler
    constructor: (@device) ->

    setup: ->
      @dependOnDevice(@device)
      super()

    # ### executeAction()
    executeAction: (simulate) =>
      return (
        if simulate
          Promise.resolve __("would reset %s", @device.name)
        else
          @device.resetSmartmeterDegreedays().then( => __("reset %s", @device.name) )
      )
    # ### hasRestoreAction()
    hasRestoreAction: -> false


  class Sampler
    constructor: () ->
      @samples = []

    addSample: (@_sample) ->
      @samples.push Number @_sample

    getAverage: (reset = false)->
      result = 0
      if @samples.length > 0
        for r in @samples
          result += r
        result /= @samples.length
        if reset
          @samples = []
      return result

  return plugin
