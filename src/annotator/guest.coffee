baseURI = require('document-base-uri')
extend = require('extend')
raf = require('raf')
scrollIntoView = require('scroll-into-view')

Annotator = require('annotator')
$ = Annotator.$

adder = require('./adder')
highlighter = require('./highlighter')
rangeUtil = require('./range-util')
selections = require('./selections')
xpathRange = require('./anchoring/range')

animationPromise = (fn) ->
  return new Promise (resolve, reject) ->
    raf ->
      try
        resolve(fn())
      catch error
        reject(error)

# Normalize the URI for an annotation. This makes it absolute and strips
# the fragment identifier.
normalizeURI = (uri, baseURI) ->
  # Convert to absolute URL
  url = new URL(uri, baseURI)
  # Remove the fragment identifier.
  # This is done on the serialized URL rather than modifying `url.hash` due
  # to a bug in Safari.
  # See https://github.com/hypothesis/h/issues/3471#issuecomment-226713750
  return url.toString().replace(/#.*/, '');

module.exports = class Guest extends Annotator
  SHOW_HIGHLIGHTS_CLASS = 'annotator-highlights-always-on'

  # Events to be bound on Annotator#element.
  events:
    ".annotator-hl click":               "onHighlightClick"
    ".annotator-hl mouseover":           "onHighlightMouseover"
    ".annotator-hl mouseout":            "onHighlightMouseout"

  options:
    Document: {}
    TextSelection: {}

  # Anchoring module
  anchoring: require('./anchoring/html')

  # Internal state
  anchors: null
  visibleHighlights: false
  guestDocument: null
  guestUri: null
  isDefault: true
  hasCustomUri: false

  html: extend {}, Annotator::html,
    adder: '<hypothesis-adder></hypothesis-adder>';

  constructor: (element, options) ->
    super
    # If no options are passed, set it to an empty object
    # Avoids the need to check if options is undefined when checking properties
    if !options then options = {}

    self = this
    this.guestDocument = element.ownerDocument
    this.guestUri = options.guestUri
    this.isDefault = if options.isDefault != undefined then options.isDefault else true
    this.hasCustomUri = options.hasCustomUri || false

    this.selections = selections(@guestDocument).subscribe
      next: (range) ->
        if range
          self._onSelection(range)
        else
          self._onClearSelection()

    # Holds events, and the methods associated with these events
    # Used to call methods outside of this class
    @_eventListeners = {}
    this.anchors = []

    @setPlugins(options.plugins)

    # The default guest must instantiate certain things (eg. Crossframe)
    # Whereas the additional guests merely get these passed in
    if (this.isDefault)
      @_setupDefaultGuest()
    else
      @setCrossframe(options.crossframe)
      @setVisibleHighlights(options.showHighlights)
      @adderCtrl = options.adderCtrl

  focusAnnotation: (anchor, state) ->
    if anchor.highlights
      $(anchor.highlights).toggleClass('annotator-hl-focused', state)

  getAdderCtrl: ->
    return @adderCtrl

  getAnchors: ->
    return @anchors

  getCrossframe: ->
    return @crossframe

  # Get the document info
  getDocumentInfo: ->
    if @plugins.PDF?
      metadataPromise = Promise.resolve(@plugins.PDF.getMetadata())
      uriPromise = Promise.resolve(@plugins.PDF.uri())
    else if @plugins.Document?
      uriPromise = Promise.resolve(@plugins.Document.uri())
      metadataPromise = Promise.resolve(@plugins.Document.metadata)
    else
      uriPromise = Promise.reject()
      metadataPromise = Promise.reject()

    uriPromise = uriPromise.catch(-> decodeURIComponent(window.location.href))
    metadataPromise = metadataPromise.catch(-> {
      title: document.title
      link: [{href: decodeURIComponent(window.location.href)}]
    })

    return Promise.all([metadataPromise, uriPromise]).then ([metadata, href]) ->
      return {uri: normalizeURI(href, baseURI), metadata}

  hasSelection: ->
    return if @selectedRanges then @selectedRanges[0] != undefined else false

  scrollToAnnotation: (highlight)->
    scrollIntoView(highlight)

    # THESIS TODO: Temporary solution
    # If this not the default guest, then scroll this one into view as well.
    # No transition, go directly to the location
    if (!this.isDefault)
      defaultView = this.guestDocument.defaultView
      offset = highlight.getBoundingClientRect()
      height = this.guestDocument.body.clientHeight
      width = this.guestDocument.body.clientWidth
      scrollTop = this.guestDocument.body.scrollTop
      scrollLeft = this.guestDocument.body.scrollLeft

      top = scrollTop + offset.top - height / 2
      left = scrollLeft + offset.left - width / 2
      defaultView.scrollTo(left, top)

  setCrossframe: (crossframe) ->
    cfOptions =
      on: (event, handler) =>
        this.subscribe(event, handler)
      emit: (event, args...) =>
        this.publish(event, args)

    if (crossframe)
      @crossframe = crossframe
      @crossframe.loadGuestAnnotations(@guestUri)
      @crossframe.addGuest(cfOptions, @guestUri)
    else
      cfOptions.guestUri = @guestUri
      @addPlugin('CrossFrame', cfOptions)
      @crossframe = @plugins.CrossFrame

    this._connectAnnotationUISync(@crossframe, @guestUri)

  setPlugins: (plugins) ->
    # Set any plugins that are passed in
    for own name, plugin of plugins
      @plugins[name] = plugin

    # Ensure that we have all the plugins that guest needs
    for own name, opts of @options
      if not @plugins[name] and Annotator.Plugin[name]
        @addPlugin(name, opts)

  trigger: (eventName, args...) ->
    return unless @_eventListeners[eventName]

    for method in @_eventListeners[eventName]
      method.apply(this, args)

  listenTo: (eventName, method) ->
    @_eventListeners[eventName] = [] unless @_eventListeners[eventName]

    @_eventListeners[eventName].push(method)

  _connectAnnotationUISync: (crossframe, guestUri) ->
    self = this

    crossframe.on 'getDocumentInfo', (cb) =>
      this.getDocumentInfo()
      .then((info) -> cb(null, info))
      .catch((reason) -> cb(reason))
    , guestUri

    crossframe.on 'setVisibleHighlights', (state) =>
      this.setVisibleHighlights(state)
    , guestUri

  _onAnnotate: ->
    @createAnnotation()
    @guestDocument.getSelection().removeAllRanges()

  _onHighlight: ->
    @setVisibleHighlights(true)
    @createHighlight()
    @guestDocument.getSelection().removeAllRanges()

  _setupDefaultGuest: ->
    @setCrossframe()

    @crossframe.onConnect(=> @publish('panelReady'))
    @adderCtrl = new adder.Adder(@adder[0])

  _setupWrapper: ->
    @wrapper = @element
    this

  # These methods aren't used in the iframe-hosted configuration of Annotator.
  _setupViewer: -> this
  _setupEditor: -> this
  _setupDocumentEvents: -> this
  _setupDynamicStyle: -> this

  destroy: ->
    $('#annotator-dynamic-style').remove()

    this.selections.unsubscribe()
    @adder.remove()

    @element.find('.annotator-hl').each ->
      $(this).contents().insertBefore(this)
      $(this).remove()

    @element.data('annotator', null)

    this.removeEvents()
    @crossframe.removeGuest(@guestUri)

  anchor: (annotation) ->
    self = this
    root = @element[0]

    # Anchors for all annotations are in the `anchors` instance property. These
    # are anchors for this annotation only. After all the targets have been
    # processed these will be appended to the list of anchors known to the
    # instance. Anchors hold an annotation, a target of that annotation, a
    # document range for that target and an Array of highlights.
    anchors = []

    # The targets that are already anchored. This function consults this to
    # determine which targets can be left alone.
    anchoredTargets = []

    # These are the highlights for existing anchors of this annotation with
    # targets that have since been removed from the annotation. These will
    # be removed by this function.
    deadHighlights = []

    # Initialize the target array.
    annotation.target ?= []

    locate = (target) ->
      # Check that the anchor has a TextQuoteSelector -- without a
      # TextQuoteSelector we have no basis on which to verify that we have
      # reanchored correctly and so we shouldn't even try.
      #
      # Returning an anchor without a range will result in this annotation being
      # treated as an orphan (assuming no other targets anchor).
      if not (target.selector ? []).some((s) => s.type == 'TextQuoteSelector')
        return Promise.resolve({annotation, target})

      # Find a target using the anchoring module.
      options = {
        cache: self.anchoringCache
        ignoreSelector: '[class^="annotator-"]'
      }
      return self.anchoring.anchor(root, target.selector, options)
      .then((range) -> {annotation, target, range})
      .catch(-> {annotation, target})

    highlight = (anchor) ->
      # Highlight the range for an anchor.
      return anchor unless anchor.range?
      return animationPromise ->
        range = xpathRange.sniff(anchor.range)
        normedRange = range.normalize(root)
        highlights = highlighter.highlightRange(normedRange)

        $(highlights).data('annotation', anchor.annotation)
        anchor.highlights = highlights
        return anchor

    sync = (anchors) ->
      # Store the results of anchoring.

      # An annotation is considered to be an orphan if it has at least one
      # target with selectors, and all targets with selectors failed to anchor
      # (i.e. we didn't find it in the page and thus it has no range).
      hasAnchorableTargets = false
      hasAnchoredTargets = false
      for anchor in anchors
        if anchor.target.selector?
          hasAnchorableTargets = true
          if anchor.range?
            hasAnchoredTargets = true
            break
      annotation.$orphan = hasAnchorableTargets and not hasAnchoredTargets

      # Add the anchors for this annotation to instance storage.
      self.anchors = self.anchors.concat(anchors)

      # Let plugins know about the new information.
      self.plugins.CrossFrame?.sync([annotation])

      self.trigger('anchorsSynced')
      return anchors

    # Remove all the anchors for this annotation from the instance storage.
    for anchor in self.anchors.splice(0, self.anchors.length)
      if anchor.annotation is annotation
        # Anchors are valid as long as they still have a range and their target
        # is still in the list of targets for this annotation.
        if anchor.range? and anchor.target in annotation.target
          anchors.push(anchor)
          anchoredTargets.push(anchor.target)
        else if anchor.highlights?
          # These highlights are no longer valid and should be removed.
          deadHighlights = deadHighlights.concat(anchor.highlights)
          delete anchor.highlights
          delete anchor.range
      else
        # These can be ignored, so push them back onto the new list.
        self.anchors.push(anchor)

    # Remove all the highlights that have no corresponding target anymore.
    raf -> highlighter.removeHighlights(deadHighlights)

    # Anchor any targets of this annotation that are not anchored already.
    for target in annotation.target when target not in anchoredTargets
      anchor = locate(target).then(highlight)
      anchors.push(anchor)

    return Promise.all(anchors).then(sync)

  detach: (annotation) ->
    anchors = []
    targets = []
    unhighlight = []

    for anchor in @anchors
      if anchor.annotation is annotation
        unhighlight.push(anchor.highlights ? [])
      else
        anchors.push(anchor)

    this.anchors = anchors

    unhighlight = Array::concat(unhighlight...)
    raf =>
      highlighter.removeHighlights(unhighlight)
      @trigger('highlightsRemoved')

  createAnnotation: (annotation = {}) ->
    self = this
    root = @element[0]

    ranges = @selectedRanges ? []
    @selectedRanges = null

    getSelectors = (range) ->
      options = {
        cache: self.anchoringCache
        ignoreSelector: '[class^="annotator-"]'
      }
      # Returns an array of selectors for the passed range.
      return self.anchoring.describe(root, range, options)

    setDocumentInfo = (info) ->
      annotation.document = info.metadata
      # If this guest has a custom guestUri, then use that as the uri value
      annotation.uri = if (self.hasCustomUri) then self.guestUri else info.uri

    setTargets = ([info, selectors]) ->
      # `selectors` is an array of arrays: each item is an array of selectors
      # identifying a distinct target.
      source = info.uri
      annotation.target = ({source, selector} for selector in selectors)

    info = this.getDocumentInfo()
    selectors = Promise.all(ranges.map(getSelectors))

    metadata = info.then(setDocumentInfo)
    targets = Promise.all([info, selectors]).then(setTargets)

    targets.then(-> self.publish('beforeAnnotationCreated', [annotation]))
    targets.then(-> self.anchor(annotation))

    @trigger('createAnnotation', annotation)
    annotation

  createHighlight: ->
    return this.createAnnotation({$highlight: true})

  # Create a blank comment (AKA "page note")
  createComment: () ->
    annotation = {}
    self = this

    prepare = (info) ->
      annotation.document = info.metadata
      annotation.uri = info.uri
      annotation.target = [{source: info.uri}]

    this.getDocumentInfo()
      .then(prepare)
      .then(-> self.publish('beforeAnnotationCreated', [annotation]))

    annotation

  _focusSidebarAnnotations: (annotations) ->
    tags = @_getTags(annotations)
    @crossframe?.call('focusAnnotations', tags)

  _showSidebarAnnotations: (annotations) ->
    tags = @_getTags(annotations)
    @crossframe?.call('showAnnotations', tags)
    @trigger('showSidebarAnnotations')

  _toggleSidebarAnnotationSelection: (annotations) ->
    tags = @_getTags(annotations)
    @crossframe?.call('toggleAnnotationSelection', tags)

  _updateSidebarAnnotations: (annotations) ->
    tags = @_getTags(annotations)
    @crossframe?.call('updateAnnotations', tags)

  _getTags: (annotations) ->
    return (a.$tag for a in annotations)

  _onSelection: (range) ->
    selection = @guestDocument.getSelection()
    isBackwards = rangeUtil.isSelectionBackwards(selection)
    focusRect = rangeUtil.selectionFocusRect(selection)
    if !focusRect
      # The selected range does not contain any text
      this._onClearSelection()
      return

    @selectedRanges = [range]

    Annotator.$('.annotator-toolbar .h-icon-note')
      .attr('title', 'New Annotation')
      .removeClass('h-icon-note')
      .addClass('h-icon-annotate');

    this.adderCtrl.setGuest({
      'onAnnotate': @_onAnnotate.bind(this),
      'onHighlight': @_onHighlight.bind(this),
      'guestElement': @guestDocument.body,
    })

    {left, top, arrowDirection} = this.adderCtrl.target(focusRect, isBackwards)
    this.adderCtrl.showAt(left, top, arrowDirection)

  _onClearSelection: () ->
    this.adderCtrl.hide()
    @selectedRanges = []

    Annotator.$('.annotator-toolbar .h-icon-annotate')
      .attr('title', 'New Page Note')
      .removeClass('h-icon-annotate')
      .addClass('h-icon-note');

  selectAnnotations: (annotations, toggle) ->
    if toggle
      this._toggleSidebarAnnotationSelection annotations
    else
      this._showSidebarAnnotations annotations

  onHighlightMouseover: (event) ->
    return unless @visibleHighlights
    annotation = $(event.currentTarget).data('annotation')
    annotations = event.annotations ?= []
    annotations.push(annotation)

    # The innermost highlight will execute this.
    # The timeout gives time for the event to bubble, letting any overlapping
    # highlights have time to add their annotations to the list stored on the
    # event object.
    if event.target is event.currentTarget
      setTimeout => this._focusSidebarAnnotations(annotations)

  onHighlightMouseout: (event) ->
    return unless @visibleHighlights
    this._focusSidebarAnnotations([])

  onHighlightClick: (event) ->
    return unless @visibleHighlights
    annotation = $(event.currentTarget).data('annotation')
    annotations = event.annotations ?= []
    annotations.push(annotation)

    # See the comment in onHighlightMouseover
    if event.target is event.currentTarget
      xor = (event.metaKey or event.ctrlKey)
      setTimeout => this.selectAnnotations(annotations, xor)

  # Pass true to show the highlights in the frame or false to disable.
  setVisibleHighlights: (shouldShowHighlights) ->
    @crossframe?.call('setVisibleHighlights', shouldShowHighlights)
    this.toggleHighlightClass(shouldShowHighlights)
    this.publish 'setVisibleHighlights', shouldShowHighlights

  toggleHighlightClass: (shouldShowHighlights) ->
    if shouldShowHighlights
      @element.addClass(SHOW_HIGHLIGHTS_CLASS)
    else
      @element.removeClass(SHOW_HIGHLIGHTS_CLASS)

    @visibleHighlights = shouldShowHighlights
