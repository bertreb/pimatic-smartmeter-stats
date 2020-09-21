module.exports = (env) ->
  Promise = env.require 'bluebird'
  assert = env.require 'cassert'
  types = env.require('decl-api').types
  fs = env.require('fs')
  M = env.matcher
  Moment = require 'moment-timezone'
  path = require 'path'
  converter = require('json-2-csv')

  _ = env.require('lodash')

  CronJob = env.CronJob or require('cron').CronJob

  # cron definitions
  every5Minute = "0 */5 * * * *"
  everyMinute = "0 * * * * *"
  everySample = "10 */15 * * * *" # every 15 minutes + 10 seconds
  everyHour = "0 0 * * * *"
  everyDay = "0 1 0 * * *" # at midnight at 00:01
  everyWeek = "0 2 0 * * 1" # monday at 00:02
  everyMonth = "0 3 0 1 * *" # first day of the month at 00:03

  # cron test definitions
  every5MinuteTest = "*/30 * * * * *" # every 30 seconds
  everyHourTest = "0 * * * * *" # every minute
  everyDayTest = "2 */2 * * * *" # every 2 minutes + 2 seconds
  everyWeekTest = "20 */3 * * * *" # every 3 minutes and 20 seconds
  everyMonthTest = "30 */5 * * * *" #every 5 minutes and 30 seconds

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
      @framework.deviceManager.registerDeviceClass('SmartmeterLoggerDevice', {
        configDef: deviceConfigDef.SmartmeterLoggerDevice,
        createCallback: (config, lastState) => new SmartmeterLoggerDevice(config, lastState, @framework, @dirPath)
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

      @attributeList = ["actual", "actualday", "fiveminute", "lastfiveminute", "hour", "lasthour", "day", "lastday", "week", "lastweek", "month", "lastmonth"]
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
      @attributeValues.actualday = lastState?.actualday?.value or 0.0
      @attributeValues.fiveminute = lastState?.fiveminute?.value or 0.0
      @attributeValues.lastfiveminute = lastState?.lastfiveminute?.value or 0.0
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
          if val >= @attributeValues.actual
            @emit "actual", val
            @attributeValues.actual = val
            @attributeValues.actualday = val - @attributeValues.lastday
            @emit "actualday", @attributeValues.actualday
          if @init == true # set all lastValues to the current input value
            @attributeValues.lastfiveminute = val if @attributeValues.lastfiveminute is 0
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
            when "fiveminute"
              @updateJobs.push new CronJob
                cronTime:  if @config.test then every5MinuteTest else every5Minute
                onTick: =>
                  @attributeValues.fiveminute = @attributeValues.actual - @attributeValues.lastfiveminute
                  @attributeValues.lastfiveminute = @attributeValues.actual
                  @emit "fiveminute", @attributeValues.fiveminute
                  @emit "lastfiveminute", @attributeValues.lastfiveminute
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
                  @attributeValues.actualday = 0
                  @emit "actualday", @attributeValues.actualday
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
        if @test then env.logger.debug "'" + @id + "' data is saved"
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

  class SmartmeterLoggerDevice extends env.devices.Device

    actions:
      resetSolarStats:
        description: "Resets the stats attribute values"

    constructor: (@config, lastState, @framework, @dirPath) ->

      @id = @config.id
      @name = @config.name

      @attributes = {}
      @attributeValues = {}

      @emptyRow = {}
      @nrOfSamples = 0 # @config.nrOfSamples ? 15 # default 15 minutes
      @sampleData = {}
      @updateJobs = []

      @dataFullFilename = @_getFullFileName()

      @_readData(@dataFullFilename)
      .then((data)=>
        @data = data
      )

      @attributes["lastlog"] =
        description: "the last complete log filename"
        type: "string"
        acronym: "lastlog"
        hidden: true
      @attributeValues["lastlog"] = ""
      @_createGetter("lastlog", =>
        return Promise.resolve @attributeValues["lastlog"]
      )

      for _variable in @config.variables
        for _attribute in _variable.attributes
          _attr = _attribute.attributeId
          #env.logger.debug("Device: " + _variable.deviceId + ", attribute: " + _attr)
          _newColumn = _variable.deviceId + '.' + _attr
          _var = @framework.variableManager.getVariableByName(_newColumn)
          unless _var?
            throw new Error "variable '#{_variable.deviceId}.#{_attr}' does not excist"
          if @emptyRow[_newColumn]?
            throw new Error "variable '#{_variable.deviceId}.#{_attr}' already added"

          @emptyRow[_newColumn] = 0
          @attributes[_newColumn] =
            description: _attr
            type: "number"
            unit: _var.unit ? "Wh"
            acronym: _newColumn
            default: 0.0
          @attributeValues[_newColumn] = 0.0
          @_createGetter(_newColumn, =>
            return Promise.resolve @attributeValues[_newColumn]
          )
      @sampleData = @emptyRow

      #env.logger.debug "@newRow: " + JSON.stringify(@newRow,null,2)

      @updateJobs.push new CronJob
        cronTime:  everyMinute
        onTick: =>
          for _variable in @config.variables
            for _attribute in _variable.attributes
              _column = _variable.deviceId + '.' + _attribute.attributeId
              _value = @framework.variableManager.getVariableValue(_column)
              @sampleData[_column] = @sampleData[_column] + _value
              @emit _column, _value
          @nrOfSamples += 1
          env.logger.debug("sampleData: " + JSON.stringify(@sampleData,null,2) + ", nrOfSamples " + @nrOfSamples)

      @updateJobs.push new CronJob
        cronTime:  everySample
        onTick: =>
          _newSampleRow = {}
          d = new Date()
          moment = Moment(d)
          timestamp = moment.format("YYYY-MM-DD HH:mm")
          _newSampleRow["timestamp"] = timestamp
          # calculate average per column and add average to sampleRow
          for _variable in @config.variables
            for _attribute in _variable.attributes
              _column = _variable.deviceId + '.' + _attribute.attributeId
              _newSampleRow[_column] = @sampleData[_column] / @nrOfSamples # aantal samples
          # add sampleRow tot @data
          @nrOfSamples = 0
          @data.push _newSampleRow

          @_saveData(@dataFullFilename,@data)
          # reset @sampleData
          for i, _data of @sampleData
            @sampleData[i] = 0
          env.logger.debug "data: " + JSON.stringify(@data,null,2)

      @updateJobs.push new CronJob
        cronTime:  everyDay
        onTick: =>
          @data = []
          @emit "lastlog", @dataFullFilename
          @dataFullFilename = @_getFullFileName() # new day is new file

      if @updateJobs?
        for jb in @updateJobs
          jb.start()

      super()

    _getFullFileName:()=>
      d = new Date()
      moment = Moment(d)
      datestamp = moment.format("YYYYMMDD")

      _dataFullFilename = path.join(@dirPath, './' + datestamp + '-' + @id + '.csv')

      return _dataFullFilename


    _readData: (_dataFullFilename) =>
      return new Promise( (resolve, reject) =>
        if fs.existsSync(_dataFullFilename)
          fs.readFile(_dataFullFilename, 'utf8', (err, data) =>
            if err?
              env.logger.debug "Handled error readData " + err
              _data = []
              resolve _data
            converter.csv2json(data, (err, data)=>
              if err?
                env.logger.debug "Handled error csv2json " + err
                _data = []
                resolve _data
              resolve data
            )
          )
        else
          _data = []
          resolve _data
    )

    _saveData: (_dataFullFilename, data) =>
      return new Promise( (resolve, reject) =>
        converter.json2csv(data, (err, _csvData) =>
          if err?
            env.logger.debug "Handled error json2csv " + err
            reject()
          fs.writeFileSync(_dataFullFilename, _csvData,'utf8')
          resolve()
        )
      )

    resetSmartmeterStats: () ->
      Promise.resolve()

    destroy: ->
      @_saveData(@dataFullFilename,@data)
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
      ###
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
      ###

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
      #@calcTemperature = if @config.calcTemperature? then @config.calcTemperature else @baseTemperature
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
      #@attributeValues.baseTemp = lastState?.baseTemp?.value or 0.0
      #@attributeValues.calcTemp = lastState?.calcTemp?.value or 0.0

      #load temp variables
      if fs.existsSync(@ddVarsFullFilename)
        data = fs.readFileSync(@ddVarsFullFilename, 'utf8')
        env.logger.debug "loading '" + @id + "' variables data ..."
        tempData = JSON.parse(data)
        @_tempLastHour = tempData.tempLastHour
        @_tempInLastHour = tempData.tempInLastHour
        @_windspeedLastHour = tempData.windspeedLastHour
        @attributeValues.energyTotalLastDay = tempData.energyTotalLastDay
        @tempSampler.setData(tempData.tempSampler)
        @tempInSampler.setData(tempData.tempInSampler)
        @windspeedSampler.setData(tempData.windspeedSampler)
        @degreedaysSampler.setData(tempData.degreedaysSampler)
        @attributeValues.statusLevel = lastState?.statusLevel?.value or 1
        @init = false
      else
        @attributeValues.statusLevel = 1
        @init = true
      #_baseTemp = @framework.variableManager.getVariableByName(@inputBaseTempName)
      #if _baseTemp? then @baseTemperature = _baseTemp.value
      @attributeValues.status = @states[@attributeValues.statusLevel]
      @baseTemperature = @config.baseTemperature

      unless @framework.variableManager.getVariableByName(@temperatureName)?
        throw new Error("'" + @temperatureName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@temperatureInName)? or @temperatureInName is ""
        throw new Error("'" + @temperatureInName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@windspeedName)? or @windspeedName is ""
        throw new Error("'" + @windspeedName + "' does not excist")
      unless @framework.variableManager.getVariableByName(@energyName)?
        throw new Error("'" + @energyName + "' does not excist")


      @updateJobsHour = new CronJob
        cronTime: if @test then everyHourTest else everyHour
        onTick: =>
          if @test then env.logger.info "HourTest update"
          env.logger.debug "Hourly update"
          _temp = Number @framework.variableManager.getVariableByName(@temperatureName).value
          _tempIn = if @temperatureInName isnt "" then Number @framework.variableManager.getVariableByName(@temperatureInName).value else _tempIn = null
          _windspeed = if @windspeedName isnt "" then Number @framework.variableManager.getVariableByName(@windspeedName).value else _windspeed = null
          _energy = Number @framework.variableManager.getVariableByName(@energyName).value
          unless @attributeValues.energyTotalLastDay? then @attributeValues.energyTotalLastDay = _energy
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

          #add hour values to samplers for day calculation
          @tempSampler.addSample _temperatureHour
          @tempInSampler.addSample _temperatureInHour
          @windspeedSampler.addSample _windspeedHour
          _dd = @_degreedays.calculate(@baseTemperature, _temperatureHour, _windspeedHour) # calc degreedays Hour for current temperature and wind
          @degreedaysSampler.addSample _dd

      @updateJobsDay = new CronJob
        cronTime: if @test then everyDayTest else everyDay
        onTick: =>
          if @test then env.logger.info "DayTest update"
          env.logger.debug "Daily update"
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
          #@attributeValues.baseTemp = @baseTemperature
          #@attributeValues.calcTemp = @calcTemperature
          @attributeValues.r2 = 0

          if @logging
            @_saveData(@ddDataFullFilename)
            .then (logData) =>
              env.logger.debug "tot hier logData received"
              #env.logger.info "DATA2: " + JSON.stringify(logData)
              @btt.setData(@baseTemperature, logData)
              .then (newData) =>
                env.logger.debug "newData received"
                _reg = @btt.getRegression(newData)
                env.logger.debug "_reg: " + JSON.stringify(_reg)
                @attributeValues.r2 = _reg.r2
                #@attributeValues.baseTemp = @baseTemperature
                @emit 'r2', @attributeValues.r2
              .catch (err) =>
                env.logger.error "setDate, data not set: " + err
            .catch (err) =>
              env.logger.error "_saveData, data not saved: " + err

          for _attrName of @attributes
            do (_attrName) =>
              @emit _attrName, @attributeValues[_attrName]

      if @updateJobsDay? then @updateJobsDay.start()
      if @updateJobsHour? then @updateJobsHour.start()

      @inputBaseTempName = "inputBaseTemp"
      @framework.variableManager.waitForInit()
      .then () =>
        @_readLog(@ddDataFullFilename)
        .then (logData) =>
          @btt = new baseTemperatureTracker(@baseTemperature, logData)
          if logData.length>0
            env.logger.debug "Checking '" + @id + "' saved data ..."
            _reg = @btt.getRegression(logData)
            env.logger.debug "'" + @id + "' Saved data loaded, " + logData.length + " days of data"
            @attributeValues.r2 = _reg.r2
            #@attributeValues.baseTemp =  @baseTemperature
            @emit 'r2', @attributeValues.r2

        .catch (err) =>
          env.logger.error "Error in @_readlog: " + err
          logData = []
          @attributeValues.r2 = 0
          #@attributeValues.baseTemp = @baseTemperature
          @emit 'r2', @attributeValues.r2

        #check on number of sample days for regression
        ###
        @framework.on 'variableValueChanged', @changeListener = (changedVar, value) =>
          if changedVar.name is @inputBaseTempName and Number value isnt @attributeValues.baseTemp
            env.logger.info "baseTemp changed to :" + Number value
            @baseTemperature = Number value
            @attributeValues.baseTemp = @baseTemperature
            @emit 'baseTemp', @attributeValues.baseTemp
            @_readLog(@ddDataFullFilename)
            .then (logData) =>
              #env.logger.info "DATA: " + JSON.stringify(logData)
              @btt.setData(@attributeValues.baseTemp, logData)
              .then (newData) =>
                _reg = @btt.getRegression(newData)
                env.logger.info "Basetemp changed _reg: " + JSON.stringify(_reg)
                if _reg.status
                  @attributeValues.r2 = _reg.r2
                  @attributeValues.baseTemp = @baseTemperature
                  #@attributeValues.calcTemp = @btt.findBaseTemperature()
                @emit 'r2', @attributeValues.r2
                #@emit 'calcTemp', @attributeValues.calcTemp
              .catch (err) =>
                env.logger.error "Var changed setData error: " + err
        ###

      @framework.on 'destroy', =>
        env.logger.debug "Shutting down ... saving variables of '" + @id + "'"
        @_saveVars(@ddVarsFullFilename)
        env.logger.debug "Variables '" + @id + "' saved"

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

    _readLog: (_dataFullFilename) =>
      return new Promise( (resolve, reject) =>
        #degreedaysData = []
        if fs.existsSync(_dataFullFilename)
          fs.readFile(_dataFullFilename, 'utf8', (err, data) =>
            if !(err)
              degreedaysData = JSON.parse(data)
              resolve(degreedaysData)
            else
              env.logger.error err
              reject()
          )
        else
          degreedaysData =[]
          #@attributeValues.statusLevel = 1
          #@attributeValues.status = @states[@attributeValues.statusLevel]
          resolve(degreedaysData)
      )

    _saveData: (@_dataFullFilename) =>
      return new Promise( (resolve, reject) =>
        d = new Date()
        moment = Moment(d).subtract(1, 'days')
        timestampDatetime = moment.format("YYYY-MM-DD")
        @_readLog(@_dataFullFilename)
        .then (degreedaysData) =>
          #if fs.existsSync(_dataFullFilename)
          #  data = fs.readFileSync(_dataFullFilename, 'utf8')
          #  degreedaysData = JSON.parse(data)
          #else
          #  degreedaysData = []

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
          env.logger.debug "'" + @id + "' data is written to log"
          fs.writeFileSync(@_dataFullFilename, @_prettyCompactJSON(degreedaysData),'utf8')
          env.logger.debug "Log of '" + @id + "' saved"
          env.logger.info "Log of '" + @id + "' saved"
          resolve(degreedaysData)
        .catch (err) =>
          env.logger.error "_saveData @_readLog error: " + err
          reject()
      )


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


    destroy: ->
      if @updateJobsDay? then @updateJobsDay.stop()
      if @updateJobsHour? then @updateJobsHour.stop()
      #@framework.variableManager.removeListener('variableValueChanged', @changeListener)
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

    calculate: (base, temp, wind) =>
      #env.logger.info "base: " + base + ", temp: " + temp + ", wind: " + wind
      currentMonth = (new Date).getMonth() # 0=january
      factor = 1.0 # April and October
      factor = 0.8 if currentMonth >= 4 && currentMonth <= 8 # May till September
      factor = 1.1 if currentMonth <=1 || currentMonth >= 10 # November till March
      _degreedays = factor * ( base - temp + (2/3) * wind)
      _degreedays = 0 unless _degreedays > 0
      #env.logger.info "base: " + base + ", temp: " + temp + ", wind: " + wind + " ,@degreedays: " + _degreedays
      return _degreedays

  class Sampler
    constructor: () ->
      @samples = []

    addSample: (@_sample) =>
      @samples.push Number @_sample

    getAverage: (reset = false)=>
      result = 0
      if @samples.length > 0
        for r in @samples
          result += r
        result /= @samples.length
        if reset
          @samples = []
      return result

    getData: () =>
      return @samples

    setData: (_samples) =>
      @samples = _samples

  class baseTemperatureTracker
    constructor: (baseTemp, _samples) ->
      @samples = _samples ? []
      @baseTemperature = baseTemp
      @_degreedays = new Degreedays()
      @daysForRegression = 10

    setData: (baseTemp, _samples) =>
      return new Promise( (resolve,reject) =>
        #_newSamples = []
        unless _samples?
          reject()
        #baseTemperature = baseTemp
        #for _sample in _samples
        #  _sample.degreedays = @_degreedays.calculate(baseTemp, _sample.temperature, _sample.wind)
        #  _newSamples.push _sample
        resolve(_samples)
      )

    getDaysForRegression: =>
      return @daysForRegression

    getRegression: (_data) =>
      #_samples =[{temperatureDay, temperatureInDay, windspeedDay, energyDay, degreedaysDay, efficiencyDay}]
      lr =
        slope: 0
        intercept: 0
        r2: 0
        status: off
        waitdays: @daysForRegression
        size: _.size(_data) ? 0

      #env.logger.info "@samples: " + JSON.stringify(@samples)
      #env.logger.info "lr1: " + lr

      if not _data? or lr.size is 0
        return lr
      if lr.size < @daysForRegression # test on minimum number of datasets for regression
        lr.waitdays = @daysForRegression - lr.size
        lr.status = off
        return lr

      x = []
      y = []
      for _s in _data
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
      lr.r2 = 100 * Math.pow((n*sum_xy - sum_x*sum_y)/Math.sqrt((n*sum_xx-sum_x*sum_x)*(n*sum_yy-sum_y*sum_y)),2)
      if Number.isNaN(lr.r2)
        env.logger.debug lr
        lr.slope = 0
        lr.intercept = 0
        lr.r2 = 0
        lr.status = off
        return lr

      #env.logger.info "lr2: " + JSON.stringify(lr)

      lr.waitdays = 0
      lr.status = on
      return lr

    findBaseTemperature: () =>

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
        _samples = @samples
        for _sample, i in _samples
          _newDegreedays = @_degreedays.calculate(baseTemp, _sample.temperature, _sample.wind)
          @samples[i].degreedays = _newDegreedays
        R2 = @getRegression().r2
        direction = -1 * direction if R2 <= lastR2
        step /= 2
        lastR2 = R2
      return tempValue

  return plugin
