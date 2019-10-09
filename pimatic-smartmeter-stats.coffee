module.exports = (env) ->
  Promise = env.require 'bluebird'
  assert = env.require 'cassert'
  types = env.require('decl-api').types
 
  class SmartmeterStatsPlugin extends env.plugins.Plugin
    init: (app, @framework, @config) =>
      deviceConfigDef = require('./device-config-schema')
      @framework.deviceManager.registerDeviceClass('SmartmeterStatsDevice', {
        configDef: deviceConfigDef.SmartmeterStatsDevice,
        createCallback: (config, lastState) => new SmartmeterStatsDevice(config, lastState, @framework)
      })
  
  plugin = new SmartmeterStatsPlugin
 
  class SmartmeterStatsDevice extends env.devices.Device

    actual: 0.0
    hour: 0.0
    day: 0.0
    week: 0.0
    month: 0.0

    constructor: (@config, lastState, @framework) ->
      @id = @config.id
      @name = @config.name
      @input = @config.input
      @expression = @config.expression
      @startHour = if @config.startHour? then @config.startHour else 0
      @unit = if @config.unit? then @config.unit else "string"
      @_vars = @framework.variableManager
      @_exprChangeListeners = []
      @_lastHour = 0.0
      @_lastDay = 0.0
      @_lastWeek = 0.0
      @_lastMonth = 0.0
      @init = true

      @attributes = {}

      @expression = @expression.replace /(^[a-z])|([A-Z])/g, ((match, p1, p2, offset) =>
              (if offset>0 then " " else "") + match.toUpperCase())

      @attributes[@input] = {
        name: @input
        acronym: @input
        description: "The name of the input variable."
        type: types.number
        unit: @unit
      }

      parseExprAndAddListener = ( () =>
        #env.logger.info input.expression
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
          @emit @input, val
          @actual = val
          if @init # set all lastValues to the current input value
            @_lastHour = val
            @_lastDay = val
            @_lastWeek = val
            @_lastMonth = val
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
          if val isnt @_attributesMeta[@input].value
            @emit @input, val
          return val
        )
      )
      #env.logger.info @source + " ==== " + getValue
      @_createGetter(@input, getValue)

      for attributeName in @config.statistics
        do (attributeName) =>
          @attributes[attributeName] =
            name: attributeName
            type: types.number
            description: attributeName
            acronym: attributeName
            unit: @unit
          switch attributeName
            when "hour"
              @_createGetter attributeName, () =>
                return Promise.resolve @hour
            when "day"
              @_createGetter attributeName, () =>
                return Promise.resolve @day
            when "week"
              @_createGetter attributeName, () =>
                return Promise.resolve @week
            when "month"
              @_createGetter attributeName, () =>
                return Promise.resolve @month

    

      scheduleUpdate = () =>
        timestamp = new Date()
        @_updateTimeout = setTimeout =>
          if @_destroyed then return
          for attributeName in @config.statistics
            do (attributeName) =>
              switch attributeName
                when "hour"
                  @hour = if (!(@_lastHour?) or @_lastHour == 0) then 0 else @actual - @_lastHour
                  @_lastHour = @actual
                  @emit "hour", @hour
                when "day"
                  if (timestamp.getHours() == 0 && timestamp.getMinutes() == 0) || @config.test # for testing
                    @day = if (!(@_lastDay?) or @_lastDay == 0) then 0 else @actual - @_lastDay
                    @_lastDay = @actual
                    @emit "day", @day
                when "week"
                  # test on start of week WeekDays == 1 (monday)
                  if (timestamp.getDay() == 1 && timestamp.getHours() == 0 && timestamp.getMinutes() == 0) || @config.test # for testing
                    @week = if (!(@_lastWeek?) or @_lastWeek == 0) then 0 else @actual - @_lastWeek
                    @_lastWeek = @actual
                    @emit "week", @week
                # test on start of Month == 1 (first day of month)
                when "month"
                  if (timestamp.getDate() == 1 && timestamp.getHours() == 0 && timestamp.getMinutes() == 0 ) || @config.test # for testing
                    @month = if (!(@_lastMonth?) or @_lastMonth == 0) then 0 else @actual - @_lastMonth
                    @_lastMonth= @actual
                    @emit "month", @month
          scheduleUpdate()
        , @setTimerOnHour(timestamp) # on the hour heartbeat
        
      scheduleUpdate();

      super()


    setTimerOnHour: (timestamp) =>
      # calculate millisec to next full hour
      if @config.test
        # 60 times faster timer for testing. 1 Hour is 1 Minute 
        return 60000 - 1000 * timestamp.getSeconds()
      else
        # normal timer every hour
        return 3600000 - 60000 * timestamp.getMinutes() - 1000 * timestamp.getSeconds()

    destroy: ->
      @_vars.cancelNotifyOnChange(cl) for cl in @_exprChangeListeners
      clearTimeout(@_updateTimeout)
      super()

  return plugin
