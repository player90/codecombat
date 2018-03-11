require('app/styles/courses/courses-view.sass')
RootView = require 'views/core/RootView'
template = require 'templates/courses/courses-view'
AuthModal = require 'views/core/AuthModal'
CreateAccountModal = require 'views/core/CreateAccountModal'
ChangeCourseLanguageModal = require 'views/courses/ChangeCourseLanguageModal'
HeroSelectModal = require 'views/courses/HeroSelectModal'
ChooseLanguageModal = require 'views/courses/ChooseLanguageModal'
JoinClassModal = require 'views/courses/JoinClassModal'
CourseInstance = require 'models/CourseInstance'
CocoCollection = require 'collections/CocoCollection'
Course = require 'models/Course'
Classroom = require 'models/Classroom'
Classrooms = require 'collections/Classrooms'
Courses = require 'collections/Courses'
CourseInstances = require 'collections/CourseInstances'
LevelSession = require 'models/LevelSession'
Levels = require 'collections/Levels'
NameLoader = require 'core/NameLoader'
Campaign = require 'models/Campaign'
ThangType = require 'models/ThangType'
Mandate = require 'models/Mandate'
utils = require 'core/utils'

# TODO: Test everything

module.exports = class CoursesView extends RootView
  id: 'courses-view'
  template: template

  events:
    'click #log-in-btn': 'onClickLogInButton'
    'click #start-new-game-btn': 'openSignUpModal'
    'click .change-hero-btn': 'onClickChangeHeroButton'
    'click #join-class-btn': 'onClickJoinClassButton'
    'submit #join-class-form': 'onSubmitJoinClassForm'
    'click .play-btn': 'onClickPlay'
    'click .view-class-btn': 'onClickViewClass'
    'click .view-levels-btn': 'onClickViewLevels'
    'click .view-project-gallery-link': 'onClickViewProjectGalleryLink'
    'click .view-assessments-link': 'onClickViewAssessmentsLink'

  getTitle: -> return $.i18n.t('courses.students')

  initialize: ->
    @classCodeQueryVar = utils.getQueryVariable('_cc', false)
    @courseInstances = new CocoCollection([], { url: "/db/user/#{me.id}/course_instances", model: CourseInstance})
    @courseInstances.comparator = (ci) -> return parseInt(ci.get('classroomID'), 16) + utils.orderedCourseIDs.indexOf ci.get('courseID')
    @listenToOnce @courseInstances, 'sync', @onCourseInstancesLoaded
    @supermodel.loadCollection(@courseInstances, { cache: false })
    @classrooms = new CocoCollection([], { url: "/db/classroom", model: Classroom})
    @classrooms.comparator = (a, b) -> b.id.localeCompare(a.id)
    @supermodel.loadCollection(@classrooms, { data: {memberID: me.id}, cache: false })
    @ownedClassrooms = new Classrooms()
    @ownedClassrooms.fetchMine({data: {project: '_id'}})
    @supermodel.trackCollection(@ownedClassrooms)
    @courses = new Courses()
    @courses.fetch()
    @supermodel.trackCollection(@courses)
    @originalLevelMap = {}
    @urls = require('core/urls')

    # TODO: Trim this section for only what's necessary
    @hero = new ThangType
    defaultHeroOriginal = ThangType.heroes.captain
    heroOriginal = me.get('heroConfig')?.thangType or defaultHeroOriginal
    @hero.url = "/db/thang.type/#{heroOriginal}/version"
    # @hero.setProjection ['name','slug','soundTriggers','featureImages','gems','heroClass','description','components','extendedName','shortName','unlockLevelName','i18n']
    @supermodel.loadModel(@hero, 'hero')
    @listenTo @hero, 'change', -> @render() if @supermodel.finished()

    if features.israel
      israelFinalistsRequest = @supermodel.addRequestResource url: '/db/user/-/israel-finalist-status', data: {}, method: 'GET', success: (status) =>
        return if @destroyed
        console.log {status}
        if status.finalist or me.get('name') in ['test student']
          if window.serverConfig.currentTournament is 'israel'
            @showFinalArena = true
          else
            @awaitingFinalArena = true
            @checkForTournamentStart()
        else
          @getArenaPlayCounts()
      israelFinalistsRequest.load()

  checkForTournamentStart: =>
    return if @destroyed
    $.get '/db/mandate', (data) =>
      return if @destroyed
      if data?[0]?.currentTournament is 'israel'
        @showFinalArena = true
        @awaitingFinalArena = false
        @render()
      else
        setTimeout @checkForTournamentStart, 5000

  afterInsert: ->
    super()
    unless me.isStudent() or (@classCodeQueryVar and not me.isTeacher())
      @onClassLoadError()

  onCourseInstancesLoaded: ->
    # HoC 2015 used special single player course instances
    @courseInstances.remove(@courseInstances.where({hourOfCode: true}))

    for courseInstance in @courseInstances.models
      continue if not courseInstance.get('classroomID')
      courseID = courseInstance.get('courseID')
      courseInstance.sessions = new CocoCollection([], {
        url: courseInstance.url() + '/my-course-level-sessions',
        model: LevelSession
      })
      courseInstance.sessions.comparator = 'changed'
      @supermodel.loadCollection(courseInstance.sessions, { data: { project: 'state.complete,level.original,playtime,changed' }})

  onLoaded: ->
    super()
    if @classCodeQueryVar and not me.isAnonymous()
      window.tracker?.trackEvent 'Students Join Class Link', category: 'Students', classCode: @classCodeQueryVar, ['Mixpanel']
      @joinClass()
    else if @classCodeQueryVar and me.isAnonymous()
      @openModalView(new CreateAccountModal())
    ownerIDs = _.map(@classrooms.models, (c) -> c.get('ownerID')) ? []
    Promise.resolve($.ajax(NameLoader.loadNames(ownerIDs)))
    .then(=>
      @ownerNameMap = {}
      @ownerNameMap[ownerID] = NameLoader.getName(ownerID) for ownerID in ownerIDs
      @render?()
    )
    _.forEach _.unique(_.pluck(@classrooms.models, 'id')), (classroomID) =>
      levels = new Levels()
      @listenTo levels, 'sync', =>
        return if @destroyed
        @originalLevelMap[level.get('original')] = level for level in levels.models
        @render()
      @supermodel.trackRequest(levels.fetchForClassroom(classroomID, { data: { project: "original,primerLanguage,slug,i18n.#{me.get('preferredLanguage', true)}" }}))

  courseInstanceHasProject: (courseInstance) ->
    classroom = @classrooms.get(courseInstance.get('classroomID'))
    versionedCourse = _.find(classroom.get('courses'), {_id: courseInstance.get('courseID')})
    levels = versionedCourse.levels
    _.any(levels, { shareable: 'project' })

  onClickLogInButton: ->
    modal = new AuthModal()
    @openModalView(modal)
    window.tracker?.trackEvent 'Students Login Started', category: 'Students', ['Mixpanel']

  openSignUpModal: ->
    window.tracker?.trackEvent 'Students Signup Started', category: 'Students', ['Mixpanel']
    modal = new CreateAccountModal({ initialValues: { classCode: utils.getQueryVariable('_cc', "") } })
    @openModalView(modal)

  onClickChangeHeroButton: ->
    window.tracker?.trackEvent 'Students Change Hero Started', category: 'Students', ['Mixpanel']
    modal = new HeroSelectModal({ currentHeroID: @hero.id })
    @openModalView(modal)
    @listenTo modal, 'hero-select:success', (newHero) =>
      # @hero.url = "/db/thang.type/#{me.get('heroConfig').thangType}/version"
      # @hero.fetch()
      @hero.set(newHero.attributes)
    @listenTo modal, 'hide', ->
      @stopListening modal

  onSubmitJoinClassForm: (e) ->
    e.preventDefault()
    classCode = @$('#class-code-input').val() or @classCodeQueryVar
    window.tracker?.trackEvent 'Students Join Class With Code', category: 'Students', classCode: classCode, ['Mixpanel']
    @joinClass()

  onClickJoinClassButton: (e) ->
    classCode = @$('#class-code-input').val() or @classCodeQueryVar
    window.tracker?.trackEvent 'Students Join Class With Code', category: 'Students', classCode: classCode, ['Mixpanel']
    @joinClass()

  joinClass: ->
    return if @state
    @state = 'enrolling'
    @errorMessage = null
    @classCode = @$('#class-code-input').val() or @classCodeQueryVar
    if not @classCode
      @state = null
      @errorMessage = 'Please enter a code.'
      @renderSelectors '#join-class-form'
      return
    @renderSelectors '#join-class-form'
    if me.get('emailVerified') or me.isStudent()
      newClassroom = new Classroom()
      jqxhr = newClassroom.joinWithCode(@classCode)
      @listenTo newClassroom, 'join:success', -> @onJoinClassroomSuccess(newClassroom)
      @listenTo newClassroom, 'join:error', -> @onJoinClassroomError(newClassroom, jqxhr)
    else
      modal = new JoinClassModal({ @classCode })
      @openModalView modal
      @listenTo modal, 'error', @onClassLoadError
      @listenTo modal, 'join:success', @onJoinClassroomSuccess
      @listenTo modal, 'join:error', @onJoinClassroomError
      @listenToOnce modal, 'hidden', ->
        unless me.isStudent()
          @onClassLoadError()
      @listenTo modal, 'hidden', ->
        @state = null
        @renderSelectors '#join-class-form'

  # Super hacky way to patch users being able to join class while hiding /students from others
  onClassLoadError: ->
    _.defer ->
      application.router.routeDirectly('courses/RestrictedToStudentsView')

  onJoinClassroomError: (classroom, jqxhr, options) ->
    @state = null
    if jqxhr.status is 422
      @errorMessage = 'Please enter a code.'
    else if jqxhr.status is 404
      @errorMessage = $.t('signup.classroom_not_found')
    else
      @errorMessage = "#{jqxhr.responseText}"
    @renderSelectors '#join-class-form'

  onJoinClassroomSuccess: (newClassroom, data, options) ->
    @state = null
    application.tracker?.trackEvent 'Joined classroom', {
      category: 'Courses'
      classCode: @classCode
      classroomID: newClassroom.id
      classroomName: newClassroom.get('name')
      ownerID: newClassroom.get('ownerID')
    }
    @classrooms.add(newClassroom)
    @render()
    @classroomJustAdded = newClassroom.id

    classroomCourseInstances = new CocoCollection([], { url: "/db/course_instance", model: CourseInstance })
    classroomCourseInstances.fetch({ data: {classroomID: newClassroom.id} })
    @listenToOnce classroomCourseInstances, 'sync', ->
      # TODO: Smoother system for joining a classroom and course instances, without requiring page reload,
      # and showing which class was just joined.
      document.location.search = '' # Using document.location.reload() causes an infinite loop of reloading

  onClickPlay: (e) ->
    levelSlug = $(e.currentTarget).data('level-slug')
    window.tracker?.trackEvent $(e.currentTarget).data('event-action'), category: 'Students', levelSlug: levelSlug, ['Mixpanel']
    application.router.navigate($(e.currentTarget).data('href'), { trigger: true })

  onClickViewClass: (e) ->
    classroomID = $(e.target).data('classroom-id')
    window.tracker?.trackEvent 'Students View Class', category: 'Students', classroomID: classroomID, ['Mixpanel']
    application.router.navigate("/students/#{classroomID}", { trigger: true })

  onClickViewLevels: (e) ->
    courseID = $(e.target).data('course-id')
    courseInstanceID = $(e.target).data('courseinstance-id')
    window.tracker?.trackEvent 'Students View Levels', category: 'Students', courseID: courseID, courseInstanceID: courseInstanceID, ['Mixpanel']
    course = @courses.get(courseID)
    courseInstance = @courseInstances.get(courseInstanceID)
    levelsUrl = @urls.courseWorldMap({course, courseInstance})
    application.router.navigate(levelsUrl, { trigger: true })

  onClickViewProjectGalleryLink: (e) ->
    courseID = $(e.target).data('course-id')
    courseInstanceID = $(e.target).data('courseinstance-id')
    window.tracker?.trackEvent 'Students View To Project Gallery View', category: 'Students', courseID: courseID, courseInstanceID: courseInstanceID, ['Mixpanel']
    application.router.navigate("/students/project-gallery/#{courseInstanceID}", { trigger: true })

  onClickViewAssessmentsLink: (e) ->
    classroomID = $(e.target).data('classroom-id')
    window.tracker?.trackEvent 'Students View To Student Assessments View', category: 'Students', classroomID: classroomID, ['Mixpanel']
    application.router.navigate("/students/assessments/#{classroomID}", { trigger: true })

  afterRender: ->
    super()
    rulesContent = @$el.find('#tournament-rules-content').html()
    @$el.find('#tournament-rules').popover(placement: 'bottom', trigger: 'hover', container: '#site-content-area', content: rulesContent, html: true)

  getArenaPlayCounts: ->
    @levelPlayCountMap = []
    success = (levelPlayCounts) =>
      return if @destroyed
      for level in levelPlayCounts
        @levelPlayCountMap[level._id] = playtime: level.playtime, sessions: level.sessions
      @render() if @supermodel.finished()

    levelIDs = []
    for level in @tournamentArenas()
      levelIDs.push level.id
    levelPlayCountsRequest = @supermodel.addRequestResource 'play_counts', {
      url: '/db/level/-/play_counts'
      data: {ids: levelIDs}
      method: 'POST'
      success: success
    }, 0
    levelPlayCountsRequest.load()

  tournamentArenas: ->
    if @showFinalArena
      [
        {
          name: 'The Battle of Sky Span'
          difficulty: 3
          id: 'the-battle-of-sky-span'
          image: '/file/db/level/53c80fce0ddbef000084c667/sky-Span-banner.jpg'
        }
      ]
    else if me.get('preferredLanguage') is 'he'
      [
        {
          name: 'Tesla Tesoro'
          difficulty: 4
          id: 'tesla-tesoro'
          image: '/file/db/level/58cccfb52633d31f00d74226/TeslaTesoro-hebrew.png'
        }
        {
          name: 'Elemental Wars'
          difficulty: 5
          id: 'elemental-wars'
          image: '/file/db/level/5a54e0703a12370043f21fbe/elementalwars-hebrew.png'
        }
        {
          name: 'ליווי'
          difficulty: 5
          id: 'escort-duty'
          image: '/file/db/level/5a54e22d3a12370043f223ab/Escort Duty Banner-he.png'
        }
      ]
    else
      [
        {
          name: 'Tesla Tesoro'
          difficulty: 4
          id: 'tesla-tesoro'
          image: '/file/db/level/58cccfb52633d31f00d74226/TeslaTesoro.png'
          description: 'Mix collection, peasants, and combat in this multiplayer coin-gathering arena.'
        }
        {
          name: 'Elemental Wars'
          difficulty: 5
          id: 'elemental-wars'
          image: '/file/db/level/5a54e0703a12370043f21fbe/elemental-wars.png'
          description: 'Battle for control over the icy treasure chests as your gigantic warrior marshals his armies against his mirror-match nemesis.'
        }
        {
          name: 'Escort Duty'
          difficulty: 5
          id: 'escort-duty'
          image: '/file/db/level/59c5163bdf1a4c002f275d1e/NOV02-Escort Duty Banner.png'
          description:'Go head-to-head against another player in this desert treasure chest bonanza!'
        }
      ]
