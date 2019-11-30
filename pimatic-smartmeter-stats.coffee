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
  everyHourTest = "0,15,30,45 * * * * *" # every 15 seconds
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
      @logging = if @config.log? then @config.log else false
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
            when "day"
              @updateJobs.push new CronJob
                cronTime: if @config.test then everyDayTest else everyDay
                onTick: =>
                  @attributeValues.day = @attributeValues.actual - @attributeValues.lastday
                  @attributeValues.lastday = @attributeValues.actual
                  @emit "day", @attributeValues.day
                  @emit "lastday", @attributeValues.lastday
                  if @logging
                    @_saveLog(@attributeValues.hour, @attributeValues.day, @attributeValues.week, @attributeValues.month, @unit)
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

    _saveLog: (hour, day, week, month, unit) ->
      d = new Date()
      moment = Moment(d).subtract(1, 'days')
      timestampDatetime = moment.format("YYYY-MM-DD")
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
        if @test then env.logger.info "'" + @id + "' data is saved"
        fs.writeFileSync(@statsLogFullFilename, @_prettyCompactJSON(statsData),'utf8')
      catch e
        env.logger.error e.message
        env.logger.error "Data not writen"
        return

    _prettyCompactJSON: (data) ->
      for v, i in data
        if i is 0 then str = "[\n"
        str += " " + JSON.stringify(v)
        if i isnt data.length-1 then str += ",\n" else str += "\n]"
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
      temperature:
        description: "Yesterdays average outdoor temperature"
        type: types.number
        unit: '°C'
        acronym: 'temp'
        default: 0.0
        displayFormat: "fixed, decimals:1"
      temperatureIn:
        description: "Yesterdays average indoor temperature"
        type: types.number
        unit: '°C'
        acronym: 'tempIn'
        default: null
        displayFormat: "fixed, decimals:1"
        hidden: true
      windspeed:
        description: "Yesterdays average windspeed"
        type: types.number
        unit: 'm/s'
        acronym: 'wind'
        default: 0.0
        displayFormat: "fixed, decimals:1"
        hidden: true
      energy:
        description: "Yesterdays energy usage"
        type: types.number
        unit: ''
        default: 0.0
        acronym: 'energy'
        displayFormat: "fixed, decimals:1"
      degreedays:
        description: "Yesterdays degreedays"
        type: types.number
        unit: ''
        default: 0.0
        acronym: '°day'
        displayFormat: "fixed, decimals:1"
      efficiency:
        description: "Yesterdays efficiency ratio (e-index)"
        type: types.number
        unit: 'e/°day'
        default: 0.0
        acronym: 'e-index'
        displayFormat: "fixed, decimals:1"
      r2:
        description: "Regression R2"
        type: types.number
        unit: '%'
        default: 0
        acronym: 'r2'
        displayFormat: "fixed, decimals:0"
      baseTemp:
        description: "Used BaseTemperature"
        type: types.number
        unit: '°C'
        default: ""
        acronym: 'baseTemp'
      calcTemp:
        description: "Calculated BaseTemperature"
        type: types.number
        unit: '°C'
        default: ""
        acronym: 'calcTemp'


    constructor: (@config, lastState, @framework, @dirPath) ->
      @id = @config.id
      @name = @config.name
      @test = @config.test
      @vars = if @config.stats? then @config.stats else null#.properties
      _varsAlreadySelected = []
      for _var in @vars
        do (_var) =>
          if _var in _varsAlreadySelected
            throw new Error("variable '#{_var}' already selected")
          _varsAlreadySelected.push _var

      @temperatureName = if @config.temperature[0] == "$" then @config.temperature.substr(1) else @config.temperature
      @temperatureInName = if @config.temperatureIn? then @config.temperatureIn else ""
      @energyName = if @config.energy[0] == "$" then @config.energy.substr(1) else @config.energy
      @baseTemperature = if @config.baseTemperature? then @config.baseTemperature else 18.0
      @calcTemperature = if @config.calcTemperature? then @config.calcTemperature else @baseTemperature
      @windspeedName =  if @config.windspeed? then @config.windspeed else ""
      if @temperatureInName[0]== "$" then @temperatureInName = @temperatureInName.substr(1)
      if @windspeedName[0]== "$" then @windspeedName = @windspeedName.substr(1)
      @attributes["energy"].unit = if @config.energyUnit? then @config.energyUnit else ""

      @logging = if @config.log? then @config.log else true
      @ddDataFullFilename = path.join(@dirPath, './' + @id + '-data.json')
      @ddBackupDataFullFilename = path.join(@dirPath, './backup-' + @id + '-data.json')
      @ddVarsFullFilename = path.join(@dirPath, './' + @id + '-vars.json')
      @ddBackupVarsFullFilename = path.join(@dirPath, './backup-' + @id + '-vars.json')

      @tempSampler = new Sampler()
      @tempInSampler = new Sampler()
      @windspeedSampler = new Sampler()
      @degreedaysSampler = new Sampler()

      @_degreedays = new Degreedays()

      @states = ["off", "init", "processing 1st day", "yesterday"]

      @attributeValues = {}

      @btt = new baseTemperatureTracker(@baseTemperature)

      for _attr of @attributes
        do (_attr) =>
          @attributeValues[_attr] = null
          @_createGetter(_attr, =>
            return Promise.resolve @attributeValues[_attr]
          )
          @attributes[_attr].hidden = true
          if (_attr in @vars) then @attributes[_attr].hidden = false

      @attributeValues.temperature = lastState?.temperature?.value or 0.0
      @attributeValues.temperatureIn = lastState?.temperatureIn?.value or 0.0
      @attributeValues.windspeed = lastState?.windspeed?.value or 0.0
      @attributeValues.energy = lastState?.energy?.value or 0.0
      @attributeValues.degreedays = lastState?.degreedays?.value or 0.0
      @attributeValues.efficiency = lastState?.efficiency?.value or 0.0
      @attributeValues.r2 = lastState?.r2?.value or 0
      @attributeValues.baseTemp = lastState?.baseTemp?.value or 0.0
      @attributeValues.calcTemp = lastState?.calcTemp?.value or 0.0
      @attributeValues.statusLevel = lastState?.statusLevel?.value or 1
      @attributeValues.status = lastState?.status?.value or ""

      #check on number of sample days for regression
      if fs.existsSync(@ddDataFullFilename)
        env.logger.info "Checking '" + @id + "' saved data ..."
        data = fs.readFileSync(@ddDataFullFilename, 'utf8')
        _logData = JSON.parse(data)
        _reg = @btt.getRegression(_logData)
        env.logger.info "'" + @id + "' Saved data loaded, " + _logData.length + " days of data"
        if _reg.status is on
          @attributeValues.r2 = 100 * _reg.r2
          @attributeValues.baseTemp =  @baseTemperature
          @attributes.calcTemp.hidden = false
          @attributeValues.calcTemp =  @btt.findBaseTemperature()
        else
          @attributeValues.r2 = 100 * _reg.r2
          @attributeValues.baseTemp = @baseTemperature
          @attributes.calcTemp.hidden = true
          @attributeValues.calcTemp = @baseTemperature
      else
        @attributeValues.r2 = 0
        @attributeValues.baseTemp = @baseTemperature
        @attributes.calcTemp.hidden = true
        @attributeValues.calcTemp = @baseTemperature

      #load temp variables
      if fs.existsSync(@ddVarsFullFilename)
        data = fs.readFileSync(@ddVarsFullFilename, 'utf8')
        env.logger.info "loading '" + @id + "' variables data ..."
        tempData = JSON.parse(data)
        @_tempLastHour = tempData.tempLastHour
        @_tempInLastHour = tempData.tempInLastHour
        @_windspeedLastHour = tempData.windspeedLastHour
        @attributeValues.energyTotalLastDay = tempData.energyTotalLastDay
        @tempSampler.setData(tempData.tempSampler)
        @tempInSampler.setData(tempData.tempInSampler)
        @windspeedSampler.setData(tempData.windspeedSampler)
        @degreedaysSampler.setData(tempData.degreedaysSampler)
        @init = false
      else
        @init = true


      @updateJobs2 = []

      unless @framework.variableManager.getVariableByName(@temperatureName)?
        throw new Error("'" + @temperatureName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@temperatureInName)? or @temperatureInName is ""
        throw new Error("'" + @temperatureInName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@windspeedName)? or @windspeedName is ""
        throw new Error("'" + @windspeedName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@energyName)?
        throw new Error("'" + @energyName + "' does not excist")

      @framework.on 'destroy', =>
        env.logger.info "Shutting down ... saving variables of '" + @id + "'"
        @_saveVars(@ddVarsFullFilename)
        env.logger.info "Variables '" + @id + "' saved"

      @updateJobs2.push new CronJob
        cronTime: if @test then everyHourTest else everyHour
        onTick: =>
          if @test then env.logger.info "HourTest update"
          _temp = Number @framework.variableManager.getVariableByName(@temperatureName).value
          _tempIn = if @temperatureInName isnt "" then Number @framework.variableManager.getVariableByName(@temperatureInName).value else _tempIn = null
          _windspeed = if @windspeedName isnt "" then Number @framework.variableManager.getVariableByName(@windspeedName).value else _windspeed = null
          _energy = Number @framework.variableManager.getVariableByName(@energyName).value
          if @attributeValues.energyTotalLastDay is null then @attributeValues.energyTotalLastDay = _energy
          if @init
            @_tempLastHour = _temp
            @_tempInLastHour = if @temperatureInName isnt "" then _tempIn else _tempIn = null
            @_windspeedLastHour = if @windspeedName isnt "" then _windspeed else _windspeed = 0.0
            @init = false

          _temperatureHour = (_temp + @_tempLastHour) / 2 # average value
          _temperatureInHour = (_tempIn + @_tempInLastHour) / 2  # average value
          _windspeedHour = (_windspeed + @_windspeedLastHour ) / 2  # average value

          @_tempLastHour = _temp
          @_tempInLastHour = _tempIn
          @_windspeedLastHour = _windspeed

          #add hour values to samlers for day calculation
          @tempSampler.addSample _temperatureHour
          @tempInSampler.addSample _temperatureInHour
          @windspeedSampler.addSample _windspeedHour
          _dd = @_degreedays.calculate(@baseTemperature, _temperatureHour, _windspeedHour) # calc degreedays Hour for current temperature and wind
          @degreedaysSampler.addSample _dd

      @updateJobs2.push new CronJob
        cronTime: if @test then everyDayTest else everyDay
        onTick: =>
          if @test then env.logger.info "DayTest update"
          @attributeValues.statusLevel +=1 unless @attributeValues.statusLevel >= 3
          if @attributeValues.statusLevel == 3
            moment = Moment(new Date()).subtract(1, 'days') # yesterdays info
            timestampDatetime = moment.format("YYYY-MM-DD")
            @states[3] = timestampDatetime
          @attributeValues.status = @states[@attributeValues.statusLevel]

          # calculate full day values
          _energy = Number @framework.variableManager.getVariableByName(@energyName).value # the actual energy value
          @attributeValues.temperature = @tempSampler.getAverage true
          @attributeValues.temperatureIn = @tempInSampler.getAverage true
          @attributeValues.windspeed = @windspeedSampler.getAverage true
          @attributeValues.energy = _energy - @attributeValues.energyTotalLastDay
          @attributeValues.degreedays = @degreedaysSampler.getAverage true
          @attributeValues.efficiency = if @attributeValues.degreedays > 0 then (@attributeValues.energy / @attributeValues.degreedays) else 0

          @attributeValues.energyTotalLastDay = _energy # for usage per day
          @attributeValues.baseTemp = @baseTemperature
          @attributeValues.calcTemp = @calcTemperature
          @attributeValues.r2 = null

          if @logging
            _logData = @_saveData(@ddDataFullFilename)
            _reg = @btt.getRegression(_logData)
            if _reg.status
              @attributes.calcTemp.hidden = false
              @attributeValues.r2 = _reg.r2
              @attributeValues.baseTemp = @baseTemperature
              @attributeValues.calcTemp = @btt.findBaseTemperature()

            else
              @attributes.calcTemp.hidden = true
              @attributeValues.r2 = _reg.r2
              @attributeValues.baseTemp = @baseTemperature
              @attributeValues.calcTemp = @baseTemperature
              # @baseTemperature not automaticaly adjusted
              # @btt.reset()

          for _attrName of @attributes
            do (_attrName) =>
              @emit _attrName, @attributeValues[_attrName]

      if @updateJobs2?
        for jb2 in @updateJobs2
          jb2.start()

      super()

    resetSmartmeterDegreedays: () ->
      # rename current log and vars files
      @_saveVars(@ddVarsFullFilename)
      fs.rename(@ddDataFullFilename,@ddBackupDataFullFilename, (err) =>
        if err then env.logger.error "Log file backup failed, " + err.message
        )
      fs.rename(@ddVarsFullFilename, @ddBackupVarsFullFilename, (err) =>
        if err then env.logger.error "Vars file backup failed, " + err.message
        )

      for _attrName of @attributes
        do (_attrName) =>
          _defaultVal = @attributes[_attrName].default
          @attributeValues[_attrName] = _defaultVal
          @emit _attrName, _defaultVal
      Promise.resolve()

    _prettyCompactJSON: (data) ->
      for v, i in data
        if i is 0 then str = "[\n"
        str += " " + JSON.stringify(v)
        if i isnt data.length-1 then str += ",\n" else str += "\n]"
      return str

    _saveData: (_dataFullFilename) =>
      d = new Date()
      moment = Moment(d).subtract(1, 'days')
      timestampDatetime = moment.format("YYYY-MM-DD")
      if fs.existsSync(_dataFullFilename)
        data = fs.readFileSync(_dataFullFilename, 'utf8')
        degreedaysData = JSON.parse(data)
      else
        degreedaysData = []

      update =
        id: @id
        date: timestampDatetime
        temperature: Number @attributeValues.temperature.toFixed(1)
        temperatureIn: if @attributeValues.temperatureIn? then Number @attributeValues.temperatureIn.toFixed(1) else null
        wind: if @attributeValues.windspeed? then Number @attributeValues.windspeed.toFixed(2) else null
        energy: Number @attributeValues.energy.toFixed(3)
        energyTotal: Number @attributeValues.energyTotalLastDay.toFixed(3)
        degreedays: Number @attributeValues.degreedays.toFixed(2)
        effiency: Number @attributeValues.efficiency.toFixed(2)
      degreedaysData.push update
      if @test then env.logger.info "'" + @id + "' data is written to log"
      fs.writeFileSync(_dataFullFilename, @_prettyCompactJSON(degreedaysData),'utf8')
      env.logger.info "Log of '" + @id + "' saved"

      return degreedaysData


    _saveVars: (_varsFullFilename) =>
      data = {
        tempLastHour: @_tempLastHour
        tempInLastHour: @_tempInLastHour
        windspeedLastHour: @_windspeedLastHour
        energyTotalLastDay: @attributeValues.energyTotalLastDay
        tempSampler: @tempSampler.getData()
        tempInSampler: @tempInSampler.getData()
        windspeedSampler: @windspeedSampler.getData()
        degreedaysSampler: @degreedaysSampler.getData()
      }
      fs.writeFileSync(_varsFullFilename, JSON.stringify(data,null,2), 'utf8')
      env.logger.info "Variables of '" + @id + "' saved"


    destroy: ->
      if @updateJobs2?
        jb2.stop() for jb2 in @updateJobs2
      #save all temp variables
      @_saveVars(@ddVarsFullFilename)
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


  class Degreedays
    constructor: () ->
      @degreedays = 0

    calculate: (base, temp, wind) ->
      currentMonth = (new Date).getMonth() # 0=january
      factor = 1.0 # April and October
      factor = 0.8 if currentMonth >= 4 && currentMonth <= 8 # May till September
      factor = 1.1 if currentMonth <=1 || currentMonth >= 10 # November till March
      @degreedays = factor * ( base - temp + (2/3) * wind)
      @degreedays = 0 unless @degreedays > 0
      return @degreedays

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

    getData: () ->
      return @samples

    setData: (_samples) ->
      @samples = _samples

  class baseTemperatureTracker
    constructor: (baseTemp) ->
      @samples = []
      @baseTemperature = baseTemp
      @_degreedays = new Degreedays()
      @daysForRegression = 10

    setBaseTemperature: (baseTemp) ->
      @baseTemperature = baseTemp
      #recalculate degreedays in sample array with new basetemp
      for _sample, i in @samples
        @samples[i].degreedays = @_degreedays.calculate(@baseTemperature, _sample.temperature, _sample.wind)

    getDaysForRegression: ->
      return @daysForRegression

    getRegression: (@_samples) ->

      #_samples =[{temperatureDay, temperatureInDay, windspeedDay, energyDay, degreedaysDay, efficiencyDay}]
      lr = {}
      lr.slope = 0
      lr.intercept = 0
      lr.r2 = 0
      lr.status = off
      lr.waitdays = @daysForRegression

      if not @_samples?
        return lr
      if @_samples.length < @daysForRegression # test on minimum number of datasets for regression
        lr.waitdays = @daysForRegression - @_samples.length
        lr.status = off
        return lr

      @samples = @_samples
      x = []
      y = []
      for _s in @samples
        do (_s) =>
          if _s.energy isnt 0 and _s.degreedays isnt 0
            x.push Number _s.energy
            y.push Number _s.degreedays
      n = y.length

      sum_x = 0.0
      sum_y = 0.0
      sum_xy = 0.0
      sum_xx = 0.0
      sum_yy = 0.0

      for i in [0..n-1]
        sum_x += Number x[i]
        sum_y += Number y[i]
        sum_xy += Number x[i] * Number y[i]
        sum_xx += Number x[i] * Number x[i]
        sum_yy += Number y[i] * Number y[i]

      lr.slope = (n * sum_xy - sum_x * sum_y) / (n*sum_xx - sum_x * sum_x)
      lr.intercept =  (sum_y - lr.slope * sum_x)/n
      lr.r2 = Math.pow((n*sum_xy - sum_x*sum_y)/Math.sqrt((n*sum_xx-sum_x*sum_x)*(n*sum_yy-sum_y*sum_y)),2)
      if Number.isNaN(lr.r2)
        env.logger.debug lr
        lr.slope = 0
        lr.intercept = 0
        lr.r2 = 0
        lr.status = off
        return lr

      lr.waitdays = 0
      lr.status = on
      return lr

    findBaseTemperature: () ->

      #search for optimal baseTemp in range 12 - 24 degrees celcius to get maximum R2
      startTemperature = 24.0

      # start at maximum temperature, step=6 and direction down
      tempValue = startTemperature
      step = 12
      direction = -1
      R2 = 0
      lastR2 = 0

      #itterate towards optimal baseTemperature
      while step > 0.01
        tempValue = tempValue + direction * step
        @setBaseTemperature(tempValue)
        R2 = @getRegression(@samples).r2
        direction = -1 * direction if R2 <= lastR2
        step /= 2
        lastR2 = R2
      return tempValue

  return plugin
