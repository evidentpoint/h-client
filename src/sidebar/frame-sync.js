'use strict';

var events = require('./events');
var bridgeEvents = require('../shared/bridge-events');
var metadata = require('./annotation-metadata');
var uiConstants = require('./ui-constants');

/**
 * @typedef FrameInfo
 * @property {string} uri - Current primary URI of the document being displayed
 * @property {string[]} searchUris - List of URIs that should be passed to the
 *           search API when searching for annotations on this document.
 * @property {string} documentFingerprint - Fingerprint of the document, used
 *                    for PDFs
 */

 /**
  * Return a minimal representation of an annotation that can be sent from the
  * sidebar app to a connected frame.
  *
  * Because this representation will be exposed to untrusted third-party
  * JavaScript, it includes only the information needed to uniquely identify it
  * within the current session and anchor it in the document.
  */
function formatAnnot(ann) {
  return {
    tag: ann.$tag,
    msg: {
      document: ann.document,
      target: ann.target,
      uri: ann.uri,
    },
  };
}

/**
 * This service runs in the sidebar and is responsible for keeping the set of
 * annotations displayed in connected frames in sync with the set shown in the
 * sidebar.
 */
// @ngInject
function FrameSync($rootScope, $window, Discovery, annotationUI, bridge) {

  // Set of tags of annotations that are currently loaded into the frame
  var inFrame = new Set();

  /**
   * Watch for changes to the set of annotations displayed in the sidebar and
   * notify connected frames about new/updated/deleted annotations.
   */
  function setupSyncToFrame() {
    // List of loaded annotations in previous state
    var prevAnnotations = [];
    var prevFrames = [];
    var prevPublicAnns = 0;

    annotationUI.subscribe(function () {
      var state = annotationUI.getState();
      if (state.annotations === prevAnnotations &&
          state.frames === prevFrames) {
        return;
      }

      var publicAnns = 0;
      var inSidebar = new Set();
      var added = [];

      state.annotations.forEach(function (annot) {
        if (metadata.isReply(annot)) {
          // The frame does not need to know about replies
          return;
        }

        if (metadata.isPublic(annot)) {
          ++publicAnns;
        }

        inSidebar.add(annot.$tag);
        if (!inFrame.has(annot.$tag)) {
          added.push(annot);
        }
      });
      var deleted = prevAnnotations.filter(function (annot) {
        return !inSidebar.has(annot.$tag);
      });
      prevAnnotations = state.annotations;
      prevFrames = state.frames;

      // We currently only handle adding and removing annotations from the frame
      // when they are added or removed in the sidebar, but not re-anchoring
      // annotations if their selectors are updated.
      if (added.length > 0) {
        bridge.call('loadAnnotations', added.map(formatAnnot));
        added.forEach(function (annot) {
          inFrame.add(annot.$tag);
        });
      }
      deleted.forEach(function (annot) {
        bridge.call('deleteAnnotation', formatAnnot(annot));
        inFrame.delete(annot.$tag);
      });

      var frames = annotationUI.frames();
      if (frames.length > 0) {
        if (frames.every(function (frame) { return frame.isAnnotationFetchComplete; })) {
          if (publicAnns === 0 || publicAnns !== prevPublicAnns) {
            bridge.call(bridgeEvents.PUBLIC_ANNOTATION_COUNT_CHANGED, publicAnns);
            prevPublicAnns = publicAnns;
          }
        }
      }
    });
  }

  /**
   * Listen for messages coming in from connected frames and add new annotations
   * to the sidebar.
   */
  function setupSyncFromFrame() {
    // A new annotation, note or highlight was created in the frame
    bridge.on('beforeCreateAnnotation', function (event) {
      inFrame.add(event.tag);
      var annot = Object.assign({}, event.msg, {$tag: event.tag});
      $rootScope.$broadcast(events.BEFORE_ANNOTATION_CREATED, annot);
    });

    bridge.on('destroyFrame', function (uri) {
      destroyFrame(uri);
    });

    // Anchoring an annotation in the frame completed
    bridge.on('sync', function (events_) {
      events_.forEach(function (event) {
        inFrame.add(event.tag);
        annotationUI.updateAnchorStatus(null, event.tag, event.msg.$orphan);
        $rootScope.$broadcast(events.ANNOTATIONS_SYNCED, [event.tag]);
      });
    });

    bridge.on('showAnnotations', function (tags) {
      annotationUI.selectAnnotations(annotationUI.findIDsForTags(tags));
      annotationUI.selectTab(uiConstants.TAB_ANNOTATIONS);
    });

    bridge.on('focusAnnotations', function (tags) {
      annotationUI.focusAnnotations(tags || []);
    });

    bridge.on('toggleAnnotationSelection', function (tags) {
      annotationUI.toggleSelectedAnnotations(annotationUI.findIDsForTags(tags));
    });

    bridge.on('sidebarOpened', function () {
      $rootScope.$broadcast('sidebarOpened');
    });

    // These merely relay calls from the Guest to the Host, and vise versa
    bridge.on('beforeAnnotationCreated', function(annotations) {
      bridge.call('beforeAnnotationCreated', annotations);
    });

    bridge.on('focusGuestAnnotations', function(tags, toggle) {
      bridge.call('focusGuestAnnotations', tags, toggle);
    });

    bridge.on('panelReady', function (isDefaultFrame) {
      bridge.call('panelReady', isDefaultFrame);
    });

    bridge.on('scrollToAnnotation', function (tag) {
      bridge.call('scrollToAnnotation', tag);
    });

    bridge.on('setVisibleHighlights', function (state) {
      bridge.call('setVisibleHighlights', state);
    });

    bridge.on('showSidebar', function () {
      bridge.call('showSidebar');
    });

    bridge.on('hideSidebar', function () {
      bridge.call('hideSidebar');
    });

    bridge.on('updateAnchors', function(anchors) {
      bridge.call('updateAnchors', anchors);
    });
  }

  /**
   * Query the Hypothesis annotation client in a frame for the URL and metadata
   * of the document that is currently loaded and add the result to the set of
   * connected frames.
   */
  function addFrame(channel) {
    channel.call('getDocumentInfo', function (err, info) {
      if (err) {
        channel.destroy();
        return;
      }

      annotationUI.connectFrame({
        metadata: info.metadata,
        uri: info.uri,
      });
    });
  }

  function destroyFrame(uri) {
    var frames = annotationUI.frames();
    var frameToDestroy;
    for (var i = 0; i < frames.length; i++) {
      var frame = frames[i];
      if (frame.uri === uri) {
        frameToDestroy = frame;
        break;
      }
    }
    if (frameToDestroy) annotationUI.destroyFrame(frameToDestroy);
  }

  /**
   * Find and connect to Hypothesis clients in the current window.
   */
  this.connect = function () {
    var discovery = new Discovery(window, {server: true});
    discovery.startDiscovery(bridge.createChannel.bind(bridge));
    bridge.onConnect(addFrame);

    setupSyncToFrame();
    setupSyncFromFrame();
  };

  /**
   * Focus annotations with the given tags.
   *
   * This is used to indicate the highlight in the document that corresponds to
   * a given annotation in the sidebar.
   *
   * @param {string[]} tags
   */
  this.focusAnnotations = function (tags, toggle) {
    bridge.call('focusGuestAnnotations', tags, toggle);
  };

  /**
   * Scroll the frame to the highlight for an annotation with a given tag.
   *
   * @param {string} tag
   */
  this.scrollToAnnotation = function (tag) {
    bridge.call('scrollToAnnotation', tag);
  };
}

module.exports = {
  default: FrameSync,
  formatAnnot: formatAnnot,
};
