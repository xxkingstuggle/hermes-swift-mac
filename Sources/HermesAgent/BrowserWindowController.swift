import AVFoundation
import Cocoa
import os
import UserNotifications
import WebKit

class BrowserWindow: NSWindow {
    var onPaste: (() -> Void)?
    var onFind: (() -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrev: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+V: route to the web view paste handler — but NOT when a native
        // text field (e.g. the find bar's NSSearchField) is focused.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v",
           !(firstResponder is NSText) {
            onPaste?()
            return true
        }
        // Cmd+F: open find bar (fix #37/#45)
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" {
            onFind?()
            return true
        }
        // Cmd+G: find next; Cmd+Shift+G: find previous (fix #37/#45)
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "g" {
            onFindNext?()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
           event.charactersIgnoringModifiers == "G" {
            onFindPrev?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Lets the first click on the WebView both focus it and register as a content
// click simultaneously, fixing buttons that appear unresponsive after focus moves away.
private class HermesWebView: WKWebView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

// Fix #64: transparent drag view that sits atop the WKWebView in the title-bar zone.
// With .fullSizeContentView + titlebarAppearsTransparent, WKWebView covers the native
// title bar strip and intercepts all mouse events — killing native window drag.
// -webkit-app-region: drag in the web page's CSS has no effect on NSWindow dragging.
// This overlay calls window.performDrag(with:) on mouseDown in the title-bar strip,
// restoring the expected drag-to-move behaviour. The view is fully transparent
// (no layer, no drawing) so it has no visual impact. Traffic lights live in
// NSThemeFrame above contentView and are unaffected.
private class TitleBarDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Double-click: honour the system "Double-click a window's title bar to" preference.
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize": window?.miniaturize(nil)
            case "Maximize": window?.performZoom(nil)
            default: break  // "None"
            }
            return
        }
        // Single click: pass to the window's native drag-to-move handler.
        window?.performDrag(with: event)
    }
    // No hitTest override — default NSView.hitTest is correct (point is in superview coords,
    // default returns self when point is in frame, nil otherwise).
    // No isFlipped override — the view has no subviews or drawing; isFlipped is irrelevant.
}

class BrowserWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate,
    WKScriptMessageHandler
{

    private var webView: HermesWebView!
    private var webViewHost: NSView!
    private var statusBar: NSView!

    /// Exposes the WKWebView for zoom operations called from AppDelegate menu actions.
    /// Return type is WKWebView (not the private HermesWebView subclass) so Swift's
    /// access-level rules are satisfied — callers only need page zoom anyway.
    var webViewForZoom: WKWebView? { webView }
    private var separator: NSView!
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var reconnectButton: NSButton!
    private(set) var urlString: String
    private let appTitle: String
    private(set) var connectionMode: String
    var onReconnect: (() -> Void)?
    var onNavigationFailed: (() -> Void)?
    /// Fired from windowWillClose so AppDelegate can prune its browserWindows array.
    /// Receives self so the delegate can match by identity (===) without holding a
    /// strong reference. Crucial for tab drag-out: AppKit retains the window briefly
    /// after it leaves a tab group, and without this callback the controller leaks.
    var onWindowWillClose: ((BrowserWindowController) -> Void)?
    /// Guards against onNavigationFailed firing twice (both provisional and 5xx paths
    /// can trigger on the same load event during teardown).
    private var didReportNavigationFailure = false
    /// Tracks whether the first navigation paint has occurred, so the fade-in
    /// animation (fix #52) only fires once — not on every SPA route change.
    private var hasCompletedFirstPaint = false
    // Find bar (fix #37/#45)
    private var findBar: NSView?
    private var findField: NSSearchField?
    private var findBarVisible = false
    /// Fix #64: drag overlay view — kept as a property so it can be resized on window resize.
    private var titleBarDragView: TitleBarDragView?
    /// Always-visible "+" button in the title-bar drag zone, so single-window
    /// users can discover tab support without memorizing Cmd+T (issue #75).
    /// Hidden once AppKit's native tab bar appears (≥2 tabs in the group, or
    /// the user explicitly chose Window → Show Tab Bar) so we don't double-up
    /// with AppKit's own "+" button. Toggled by `updateAppTitlebarClass(tabbed:)`.
    private var newTabButton: NSButton?
    /// The UserDefaults autosave name for the main window frame.
    /// Used for both windowFrameAutosaveName and the derived "NSWindow Frame <name>" key.
    private static let windowAutosaveName = "HermesMainWindow"
    /// The one native canvas colour used by the fixed Mac workbench before and
    /// behind WebKit, including the SSH footer and macOS 26 glass host tint.
    private static let fixedCanvasColor = NSColor(
        srgbRed: 25.0 / 255.0, green: 25.0 / 255.0, blue: 26.0 / 255.0, alpha: 1.0)
    /// Whether this window persists its frame. False for secondary multi-window/tab
    /// instances so they cascade from the front-most window instead of stacking on
    /// the same saved rect.
    private let useFrameAutosave: Bool
    /// Throttle the mic-denied alert to once per app session — avoids spamming if the
    /// user hits the mic button multiple times after having denied access.
    private static var didShowMicDeniedAlert = false
    /// Set to true before programmatic close so windowDidExitFullScreen
    /// doesn't clobber the saved full-screen preference (fix #43).
    var isIntentionalClose = false

    // Health check timer for direct mode — polls /health every 30s and
    // reflects status in the window title (fix #29). Tri-state: "port open
    // but /health failing" (reverse proxy up, hermes down) is its own state.
    private var healthTimer: Timer?
    private var healthState: HealthProbeResult = .healthy

    /// KVO observation for window.tabbedWindows. When AppKit adds or removes a
    /// tab from the group, the tab bar appears/disappears, which shifts the
    /// window's contentLayoutRect. We resize webView so its top sits below the
    /// tab bar (preventing the tab bar from clipping the web app's title bar
    /// and chat content).
    private var tabbedWindowsObservation: NSKeyValueObservation?

    /// KVO observation for webView.title — propagates `document.title` changes
    /// (i.e. the active conversation's name in hermes-webui) into window.title,
    /// which is what AppKit shows on the tab.
    private var pageTitleObservation: NSKeyValueObservation?

    /// Block-based observers for app activation changes; invalidated in deinit.
    private var appActiveObservers: [NSObjectProtocol] = []

    /// - Parameter useFrameAutosave: When true (default), the window persists its
    ///   frame to UserDefaults under HermesMainWindow. Only the *first* window of a
    ///   multi-window session should set this true; secondary windows pass false so
    ///   they cascade from the front-most window's frame instead of all stacking on
    ///   the same saved rect. AppKit's tab system shares the parent frame so the
    ///   parameter has no visible effect when the user prefers tabs.
    init(urlString: String, title: String, connectionMode: String = "direct",
         useFrameAutosave: Bool = true) {
        self.urlString = urlString
        self.appTitle = title
        self.connectionMode = connectionMode
        self.useFrameAutosave = useFrameAutosave

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 830),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // We deliberately leave `window.backgroundColor` at AppKit's default
        // for this appearance. Earlier versions painted it with the exact
        // page RGB so the title bar zone matched the page edge seamlessly,
        // but with native tabs visible the tab bar's translucent material
        // blended into that flat fill and lost its tonal contrast — the tab
        // dividers became invisible. The new-tab pre-paint colour (the
        // gap before WKWebView's first paint) is handled by
        // `webView.underPageBackgroundColor` and the documentStart
        // background-paint script, both keyed to the cached theme; setting
        // window.backgroundColor here would only affect the tab strip.
        super.init(window: window)

        // Fix #57: extend web content under the native title bar.
        // titleVisibility = .hidden removes the text draw; window.title stays set
        // (Window menu, Dock, accessibility, Mission Control).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        // The Mac browser uses one fixed dark workbench. WebUI theme/skin
        // preferences still persist and synchronize, but they no longer tint
        // native controls or split the window frame into mismatched surfaces.
        window.appearance = NSAppearance(named: .darkAqua)

        // Persist and restore window frame across launches — only for the first
        // (primary) window of the session. Secondary multi-window/tab instances skip
        // autosave so they cascade in openBrowser instead of stacking on the saved rect.
        // Must be set on the NSWindowController (self), not on the raw NSWindow.
        // Setting it on the window before super.init is clobbered by the controller's
        // own empty windowFrameAutosaveName during its setup. The controller property
        // handles both save and restore atomically.
        if useFrameAutosave {
            self.windowFrameAutosaveName = Self.windowAutosaveName
            // First launch (no saved frame yet): center the window.
            if UserDefaults.standard.object(forKey: "NSWindow Frame \(Self.windowAutosaveName)") == nil {
                window.center()
            }
        }
        // Multi-window / native tabs (#42): tabbingMode = .preferred opts THIS window
        // into AppKit's tab system regardless of the user's "Prefer Tabs When Opening
        // Documents" system preference. New windows with a matching tabbingIdentifier
        // join the current tab group automatically; the user can still pull tabs out
        // (Move Tab to New Window) or merge them back (Merge All Windows) via the
        // Window menu. The single tabbingIdentifier ensures every Hermes window can
        // merge into one tab group. Use .automatic if we ever want to honour the
        // system preference instead — current choice favours always-tabbable since
        // multi-window users tend to want both modes available regardless of pref.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "ai.get-hermes.HermesAgent.main"

        window.onPaste = { [weak self] in
            self?.handlePaste()
        }
        window.onFind = { [weak self] in
            self?.toggleFindBar()
        }
        window.onFindNext = { [weak self] in
            self?.findNext(forward: true)
        }
        window.onFindPrev = { [weak self] in
            self?.findNext(forward: false)
        }
        window.delegate = self

        buildUI()

        // Observe tab-group membership so we can shrink the webView when AppKit
        // adds a tab bar. Without this, the tab bar overlays the top of the web
        // UI (.app-titlebar and chat content) since .fullSizeContentView puts
        // webView under the title-bar zone where the tab bar renders.
        // KVO on tabbedWindows fires on the host window when any tab joins or
        // leaves the group, including this window.
        tabbedWindowsObservation = window.observe(\.tabbedWindows, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.updateWebViewLayout() }
        }
    }

    deinit {
        tabbedWindowsObservation?.invalidate()
        pageTitleObservation?.invalidate()
        appActiveObservers.forEach(NotificationCenter.default.removeObserver)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        let bounds = contentView.bounds
        let statusBarHeight: CGFloat = connectionMode == "ssh" ? 28 : 0

        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.setValue(true, forKey: "javaScriptCanAccessClipboard")
        prefs.setValue(true, forKey: "DOMPasteAllowed")
        config.preferences = prefs
        let pasteScript = WKUserScript(
            source:
                "document.addEventListener('paste', function(e) { e.stopImmediatePropagation(); }, true);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(pasteScript)

        // Route the WebUI notification API into UNUserNotificationCenter. The
        // WebUI's requestNotificationPermission and sendBrowserNotification are
        // defined by deferred scripts, so install the wrappers after they exist.
        let notificationBridgeScript = WKUserScript(
            source: """
                (function() {
                    const handler = window.webkit && window.webkit.messageHandlers
                        && window.webkit.messageHandlers.hermesNotify;
                    if (!handler) return;

                    const callbacks = Object.create(null);
                    let nextCallbackId = 0;
                    window.__hermesNativeNotificationPermission = 'default';
                    window.__hermesNativeBackgrounded = false;

                    window.__hermesNativeNotificationReply = function(id, granted, permission) {
                        if (permission) window.__hermesNativeNotificationPermission = permission;
                        const resolve = callbacks[id];
                        if (!resolve) return;
                        delete callbacks[id];
                        resolve(granted ? 'granted' : (permission || 'denied'));
                    };

                    function requestNativePermission() {
                        return new Promise(function(resolve) {
                            const id = String(++nextCallbackId);
                            callbacks[id] = resolve;
                            handler.postMessage({type: 'requestAuthorization', id: id});
                        });
                    }

                    function refreshNativePermission() {
                        return new Promise(function(resolve) {
                            const id = 'status-' + String(++nextCallbackId);
                            callbacks[id] = resolve;
                            handler.postMessage({type: 'notificationStatus', id: id});
                        });
                    }

                    function sendNativeNotification(title, body, options) {
                        options = options || {};
                        handler.postMessage({
                            type: 'send',
                            title: String(title || 'Hermes'),
                            body: String(body || ''),
                            force: !!options.force,
                            sid: options.sid == null ? '' : String(options.sid)
                        });
                        return Promise.resolve();
                    }

                    window.__hermesNativeNotificationBridge = {
                        requestPermission: requestNativePermission,
                        send: sendNativeNotification,
                        refreshPermission: refreshNativePermission
                    };

                    function HermesNativeNotification(title, options) {
                        sendNativeNotification(title, options && options.body, options);
                    }
                    try {
                        Object.defineProperty(HermesNativeNotification, 'permission', {
                            configurable: true,
                            get: function() {
                                return window.__hermesNativeNotificationPermission || 'default';
                            }
                        });
                        HermesNativeNotification.requestPermission = requestNativePermission;
                        Object.defineProperty(window, 'Notification', {
                            configurable: true,
                            writable: true,
                            value: HermesNativeNotification
                        });
                    } catch (_) {
                        // WebKit may expose Notification as a non-configurable
                        // host object. The function-level bridge below does not
                        // depend on replacing that object.
                    }

                    function renderNativePermissionStatus(permission) {
                        permission = permission || window.__hermesNativeNotificationPermission || 'default';
                        const el = document.getElementById('notificationPermissionStatus');
                        const btn = document.getElementById('notificationPermissionButton');
                        if (el) el.textContent = 'Permission: ' + permission;
                        if (btn) {
                            btn.disabled = permission === 'granted';
                            btn.setAttribute('aria-disabled', permission === 'granted' ? 'true' : 'false');
                        }
                    }

                    function installWebUINotificationBridge() {
                        let installed = false;
                        if (typeof window.requestNotificationPermission === 'function'
                            && !window.__hermesNativeRequestBridgeInstalled) {
                            window.requestNotificationPermission = function() {
                                return requestNativePermission().then(function(permission) {
                                    renderNativePermissionStatus(permission);
                                    if (typeof window.showToast === 'function') {
                                        window.showToast(permission === 'granted'
                                            ? 'Notifications enabled' : 'Notifications denied', 3000,
                                            permission === 'granted' ? undefined : 'error');
                                    }
                                    return permission;
                                });
                            };
                            window.__hermesNativeRequestBridgeInstalled = true;
                            installed = true;
                        }
                        if (typeof window.updateNotificationPermissionStatus === 'function'
                            && !window.__hermesNativeStatusBridgeInstalled) {
                            window.updateNotificationPermissionStatus = function() {
                                return refreshNativePermission().then(function(permission) {
                                    renderNativePermissionStatus(permission);
                                    return permission;
                                });
                            };
                            window.__hermesNativeStatusBridgeInstalled = true;
                            installed = true;
                        }
                        if (typeof window.sendBrowserNotification === 'function'
                            && !window.__hermesNativeSendBridgeInstalled) {
                            // Preserve the WebUI notification contract while
                            // swapping only the delivery mechanism for macOS.
                            window.sendBrowserNotification = function(title, body, options) {
                                options = options || {};
                                const force = !!options.force;
                                const forceHidden = !!options.forceHidden;
                                if (!force && !window._notificationsEnabled) return Promise.resolve();
                                if (!force && !forceHidden && !document.hidden
                                    && !window.__hermesNativeBackgrounded) return Promise.resolve();
                                return sendNativeNotification(title, body, options);
                            };
                            window.__hermesNativeSendBridgeInstalled = true;
                            installed = true;
                        }
                        renderNativePermissionStatus();
                        return installed;
                    }
                    const installTimer = setInterval(function() {
                        if (installWebUINotificationBridge()
                            && window.__hermesNativeRequestBridgeInstalled
                            && window.__hermesNativeStatusBridgeInstalled
                            && window.__hermesNativeSendBridgeInstalled) {
                            clearInterval(installTimer);
                        }
                    }, 50);
                    setTimeout(function() { clearInterval(installTimer); }, 10000);
                    refreshNativePermission().then(renderNativePermissionStatus);
                })();
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(notificationBridgeScript)

        // Suppress Web Speech API so hermes-webui falls back to its MediaRecorder + /api/transcribe
        // path. WebKit's built-in webkitSpeechRecognition only uses the macOS local speech model
        // which is unreliable; the backend transcription path works correctly.
        let speechSuppressionScript = WKUserScript(
            source: "window.SpeechRecognition = undefined; window.webkitSpeechRecognition = undefined;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(speechSuppressionScript)

        config.userContentController.add(self, name: "hermesNotify")

        // The colour the chrome was painted with at this WKWebView's birth —
        // either the cached colour (loaded by AppDelegate.loadCachedTheme on
        // launch) or the safe-dark fallback for first-ever launches. Used by
        // the theme bridge below to suppress sample reports that match it,
        // and by underPageBackgroundColor + darkModeScript further down so
        // every layer of the WebView paints this colour pre-page-load.
        let prePaintColor = Self.fixedCanvasColor
        let prePaintHex = Self.hexString(for: prePaintColor)

        // Theme bridge: keep the WebUI preference cache and sibling tabs in
        // sync. The browser window itself stays on the fixed dark Mac
        // presentation even when the persisted WebUI theme or skin changes.
        let themeBridgeScript = WKUserScript(
            source: """
                (function() {
                    // The colour the chrome was painted with at WKWebView init —
                    // either the cached colour or the safe-dark fallback. We
                    // suppress any sample that matches this so transient page-
                    // mount colours never flip the chrome unnecessarily.
                    const cachedHex = '\(prePaintHex)'.toUpperCase();
                    let lastReportedHex = null;
                    const isOpaque = (c) =>
                        c && c !== 'transparent' && c !== 'rgba(0, 0, 0, 0)';
                    function rgbStringToHex(s) {
                        const m = s.match(/^rgba?\\((\\d+)\\D+(\\d+)\\D+(\\d+)/);
                        if (!m) return s.toUpperCase();
                        return '#' + [m[1], m[2], m[3]].map(function(n) {
                            return parseInt(n, 10).toString(16)
                                .padStart(2, '0').toUpperCase();
                        }).join('');
                    }
                    // Walk the stack of elements at a viewport pixel and return the
                    // first opaque background. Robust against web apps where <html>
                    // and <body> are transparent and the actual paint comes from a
                    // child shell (#app, <main>, etc).
                    function effectiveBackgroundAt(x, y) {
                        if (!document.elementsFromPoint) return null;
                        const els = document.elementsFromPoint(x, y);
                        for (const el of els) {
                            const bg = getComputedStyle(el).backgroundColor;
                            if (isOpaque(bg)) return bg;
                        }
                        return null;
                    }
                    // Prefer the WebUI's own theme-color meta tag when present.
                    // hermes-webui v0.51.x+ exposes a <meta id="hermes-theme-color">
                    // updated by boot.js whenever theme/skin changes; this is the
                    // authoritative source of truth and is overlay-resistant
                    // (modals/lightboxes can't poison it). When the tag is absent
                    // (older server, raw page, error route) we fall back to pixel
                    // sampling at three viewport interior points.
                    function themeColorMetaBackground() {
                        const meta = document.getElementById('hermes-theme-color');
                        if (!meta) return null;
                        const content = (meta.getAttribute('content') || '').trim();
                        if (!content) return null;
                        // Defensive: only trust values that match the forms our
                        // Swift parseCSSColor() accepts (#RGB / #RRGGBB / rgb()
                        // / rgba()). Anything else (e.g. an unresolved
                        // `var(--bg)` from a future WebUI bug, an unknown CSS
                        // colour name) falls through to pixel-sampling rather
                        // than poisoning lastReportedHex with garbage and
                        // suppressing every subsequent valid sample.
                        if (!/^#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$|^rgba?\\(/.test(content)) return null;
                        return content;
                    }
                    function effectiveBackground() {
                        const meta = themeColorMetaBackground();
                        if (meta) return meta;
                        const w = window.innerWidth || 1280;
                        const h = window.innerHeight || 800;
                        // Sample a few interior points so a single oddly-coloured
                        // element under the cursor can't dominate the answer.
                        const points = [[w >> 1, h >> 1], [w >> 1, h >> 2], [w >> 2, h >> 1]];
                        for (const [x, y] of points) {
                            const bg = effectiveBackgroundAt(x, y);
                            if (bg) return bg;
                        }
                        // Fallbacks for when the document hasn't laid out yet.
                        const bodyBg = document.body ? getComputedStyle(document.body).backgroundColor : null;
                        if (isOpaque(bodyBg)) return bodyBg;
                        return getComputedStyle(document.documentElement).backgroundColor;
                    }
                    // Two-layer suppression to prevent transient mount flickers
                    // (chrome was already cream from cache → page briefly paints
                    // dark during React mount → page settles back to cream).
                    //
                    //   1. Match-suppression: if the sample matches the colour
                    //      the chrome currently shows (cachedHex initially, then
                    //      lastReportedHex after the bridge has fired), do
                    //      nothing — the chrome is already correct, no IPC, no
                    //      flicker. Any pending transient is also cleared so a
                    //      mid-flight dark sample never gets sent if the page
                    //      settles back to the chrome colour.
                    //
                    //   2. Stability gate: when the sample DOES differ from the
                    //      chrome's current colour, queue it and only fire if
                    //      it stays unchanged for STABILITY_MS. Real theme
                    //      changes propagate after the short delay; transients
                    //      are dropped before the timer fires.
                    const STABILITY_MS = 2500;
                    let pendingColor = null;
                    let pendingHex = null;
                    let pendingSkin = null;
                    let pendingTimer = null;
                    let lastReportedTheme = null;
                    let lastReportedSkin = null;
                    function currentThemeMode() {
                        const rawTheme = (localStorage.getItem('hermes-theme') || 'dark').toLowerCase();
                        return ['light', 'dark', 'system'].includes(rawTheme) ? rawTheme : 'dark';
                    }
                    function currentSkin() {
                        return (document.documentElement.dataset.skin || 'default').toLowerCase();
                    }
                    function postTheme(background, theme, skin) {
                        window.webkit.messageHandlers.hermesTheme.postMessage({
                            background: background,
                            theme: theme,
                            skin: skin
                        });
                    }
                    function report() {
                        const bg = effectiveBackground();
                        if (!bg) return;
                        const hex = rgbStringToHex(bg);
                        const theme = currentThemeMode();
                        const skin = currentSkin();
                        const themeChanged = theme !== lastReportedTheme;
                        const skinChanged = skin !== lastReportedSkin;
                        const currentChromeHex = lastReportedHex || cachedHex;
                        if (hex === currentChromeHex && !themeChanged && !skinChanged) {
                            // Chrome already shows this — drop any pending
                            // transient so the timer doesn't fire later with
                            // a stale "different" colour.
                            pendingColor = null;
                            pendingHex = null;
                            pendingSkin = null;
                            clearTimeout(pendingTimer);
                            return;
                        }
                        if (hex === currentChromeHex && (themeChanged || skinChanged)) {
                            // The effective colour can stay identical when the
                            // user changes system→dark while macOS is already
                            // dark (or system→light while already light). The
                            // mode itself is still authoritative for Swift.
                            pendingColor = null;
                            pendingHex = null;
                            pendingSkin = null;
                            clearTimeout(pendingTimer);
                            lastReportedHex = hex;
                            lastReportedTheme = theme;
                            lastReportedSkin = skin;
                            postTheme(bg, theme, skin);
                            return;
                        }
                        if (hex === pendingHex && skin === pendingSkin) return;
                        pendingColor = bg;
                        pendingHex = hex;
                        pendingSkin = skin;
                        clearTimeout(pendingTimer);
                        pendingTimer = setTimeout(function() {
                            if (pendingHex === hex && pendingSkin === skin) {
                                lastReportedHex = hex;
                                lastReportedTheme = currentThemeMode();
                                lastReportedSkin = currentSkin();
                                postTheme(bg, lastReportedTheme, lastReportedSkin);
                            }
                        }, STABILITY_MS);
                    }
                    const observer = new MutationObserver(() => requestAnimationFrame(report));
                    function start() {
                        report();
                        observer.observe(document.documentElement, {
                            attributes: true,
                            attributeFilter: ['class', 'data-theme', 'data-skin', 'style', 'data-mode']
                        });
                        if (document.body) {
                            observer.observe(document.body, {
                                attributes: true,
                                attributeFilter: ['class', 'data-theme', 'style', 'data-mode']
                            });
                        }
                        // Watch the theme-color meta tag's content attribute too
                        // — this is the new authoritative signal in v0.51.x+.
                        // boot.js updates it on every theme/skin change, so we
                        // catch toggles without waiting for the 2s poll tick.
                        const themeMeta = document.getElementById('hermes-theme-color');
                        if (themeMeta) {
                            observer.observe(themeMeta, {
                                attributes: true,
                                attributeFilter: ['content']
                            });
                        }
                        // Belt-and-suspenders: poll every 2s. Web apps that toggle
                        // theme via CSS-custom-property updates won't trigger our
                        // attribute-watcher, but the resulting backgroundColor change
                        // will be visible to elementsFromPoint on the next sample.
                        setInterval(report, 2000);
                    }
                    if (document.readyState === 'loading') {
                        document.addEventListener('DOMContentLoaded', start);
                    } else {
                        start();
                    }
                    window.addEventListener('focus', report);
                    const mq = window.matchMedia('(prefers-color-scheme: dark)');
                    if (mq.addEventListener) mq.addEventListener('change', report);
                    else if (mq.addListener) mq.addListener(report);
                })();
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(themeBridgeScript)
        config.userContentController.add(self, name: "hermesTheme")

        let webFrame = NSRect(
            x: 0, y: statusBarHeight, width: bounds.width, height: bounds.height - statusBarHeight)
        webView = HermesWebView(frame: webFrame, configuration: config)
        webView.onEffectiveAppearanceChange = { [weak self] in
            self?.handleEffectiveAppearanceChange()
        }
        webView.autoresizingMask = [.width, .height]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsMagnification = true

        // Mirror document.title into window.title so the AppKit tab shows
        // the active conversation name (truncated). KVO fires on every page
        // title change including SPA navigations.
        pageTitleObservation = webView.observe(\.title, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTabTitle() }
        }

        // Fix #23 / #52: prevent white-or-wrong-colour flash on startup. The
        // overscroll gutter and the body/html pre-paint background both need
        // to match what the page will eventually render — using the cached
        // colour avoids the dark flash that the old hardcoded #1a1a1a caused
        // on light themes during reload / new tab.
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        let darkModeScript = WKUserScript(
            source: """
                (function() {
                    // The native Mac wrapper deliberately has one fixed dark
                    // presentation, independent of the persisted WebUI skin.
                    const color = '\(prePaintHex)';
                    document.documentElement.style.background = color;
                    if (document.body) { document.body.style.background = color; }
                })();
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(darkModeScript)

        // Apply the Mac-only presentation layer without forking or mutating the
        // hosted WebUI. Keeping the stylesheet as a bundle resource makes the
        // appearance reviewable and leaves all application behaviour upstream.
        if let glassURL = Bundle.main.url(forResource: "MacGlass", withExtension: "css"),
           let glassCSS = try? String(contentsOf: glassURL, encoding: .utf8),
           let encodedCSS = try? JSONEncoder().encode(glassCSS),
           let quotedCSS = String(data: encodedCSS, encoding: .utf8) {
            let macGlassScript = WKUserScript(
                source: """
                    (function() {
                        document.documentElement.classList.add(
                            'hermes-native-glass', 'hermes-mac-fixed-theme');
                        const style = document.createElement('style');
                        style.id = 'hermes-native-glass-style';
                        style.textContent = \(quotedCSS);
                        (document.head || document.documentElement).appendChild(style);

                        function installMacChromeLayout() {
                            // Move the injected stylesheet to the end of <head>
                            // after the document parser has installed WebUI skins.
                            if (document.head && style.parentNode !== document.head) {
                                document.head.appendChild(style);
                            } else if (document.head && document.head.lastElementChild !== style) {
                                document.head.appendChild(style);
                            }

                            const main = document.querySelector('.layout > .main');
                            const layout = document.querySelector('.layout');
                            if (!main || !layout) return;

                            let updateScheduled = false;
                            function syncMainFrame() {
                                updateScheduled = false;
                                const rect = main.getBoundingClientRect();
                                const viewportWidth = window.innerWidth || document.documentElement.clientWidth;
                                document.documentElement.style.setProperty(
                                    '--hermes-main-left', Math.max(0, rect.left) + 'px');
                                document.documentElement.style.setProperty(
                                    '--hermes-main-right', Math.max(0, viewportWidth - rect.right) + 'px');
                            }
                            function scheduleMainFrameSync() {
                                if (updateScheduled) return;
                                updateScheduled = true;
                                window.requestAnimationFrame(syncMainFrame);
                            }

                            if (window.__hermesMacChromeResizeObserver) {
                                window.__hermesMacChromeResizeObserver.disconnect();
                            }
                            const resizeObserver = new ResizeObserver(scheduleMainFrameSync);
                            layout.querySelectorAll(':scope > .rail, :scope > .sidebar, :scope > .main, :scope > .rightpanel')
                                .forEach(function(column) { resizeObserver.observe(column); });
                            window.__hermesMacChromeResizeObserver = resizeObserver;
                            window.addEventListener('resize', scheduleMainFrameSync, {passive: true});
                            syncMainFrame();
                        }

                        if (document.readyState === 'loading') {
                            document.addEventListener('DOMContentLoaded', installMacChromeLayout, {once: true});
                        } else {
                            installMacChromeLayout();
                        }
                    })();
                    """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(macGlassScript)
        }

        // Fix #57: inject default traffic light clearance at documentStart.
        // Refined to exact measured pixels in injectTrafficLightWidthVar() after didFinish.
        let trafficLightScript = WKUserScript(
            source: "document.documentElement.style.setProperty('--traffic-light-width', '80px');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(trafficLightScript)

        // Replace the WebUI welcome mark with the icon bundled by the native wrapper.
        // The WebUI is external to this repository; `#emptyState .empty-logo` is
        // its exact central welcome container. Keep the replacement scoped to it
        // so title-bar and control SVGs are never affected.
        if let iconURL = Bundle.main.url(forResource: "WelcomeIcon", withExtension: "png"),
           let iconData = try? Data(contentsOf: iconURL) {
            let iconDataURL = "data:image/png;base64,\(iconData.base64EncodedString())"
            let welcomeIconScript = WKUserScript(
                source: """
                    (function() {
                        const iconURL = '\(iconDataURL)';
                        const selector = '#emptyState .empty-logo';

                        let replacementScheduled = false;
                        function replaceWelcomeIcon() {
                            replacementScheduled = false;
                            const container = document.querySelector(selector);
                            if (!container) return;
                            if (container.querySelector('img[data-hermes-native-welcome-icon="true"]')) return;

                            const source = container.querySelector('svg');
                            if (!source) return;

                            const image = document.createElement('img');
                            image.src = iconURL;
                            image.alt = source.getAttribute('aria-label') || 'Hermes';
                            image.setAttribute('data-hermes-native-welcome-icon', 'true');
                            image.style.cssText =
                                'position:relative;z-index:1;display:block;' +
                                'width:88px;height:88px;object-fit:contain;';
                            source.replaceWith(image);
                        }

                        function scheduleReplacement() {
                            if (replacementScheduled) return;
                            replacementScheduled = true;
                            window.requestAnimationFrame(replaceWelcomeIcon);
                        }

                        const observer = new MutationObserver(scheduleReplacement);
                        if (document.documentElement) {
                            observer.observe(document.documentElement, { childList: true, subtree: true });
                        }
                        document.addEventListener('DOMContentLoaded', replaceWelcomeIcon, { once: true });
                        window.addEventListener('load', replaceWelcomeIcon, { once: true });
                        replaceWelcomeIcon();
                    })();
                    """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(welcomeIconScript)
        }

        // Fix #59: hide the web app's .app-titlebar-icon (SVG logo) when running in the
        // Mac wrapper. With .fullSizeContentView the icon sits right next to the traffic
        // lights and overlaps the close button. The window title and other title bar
        // controls are unaffected.
        let hideIconScript = WKUserScript(
            source: """
                (function() {
                    const s = document.createElement('style');
                    s.textContent = '.app-titlebar-icon { visibility: hidden !important; }';
                    (document.head || document.documentElement).appendChild(s);
                })();
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(hideIconScript)

        // Hide the web app's `.app-titlebar` whenever AppKit is rendering its native
        // tab bar — the AppKit tab bar already shows the conversation name (mirrored
        // from `webView.title` via KVO), so the web titlebar's "Hermes" text becomes
        // redundant. The class is toggled by updateAppTitlebarClass(tabbed:) which
        // fires from updateWebViewLayout() and didFinish. Keeps the rule defined at
        // documentStart so the page knows about it before any layout/paint.
        let appTitlebarToggleScript = WKUserScript(
            source: """
                (function() {
                    const s = document.createElement('style');
                    s.textContent = 'body.hermes-mac-tabbed .app-titlebar { display: none !important; }';
                    (document.head || document.documentElement).appendChild(s);
                })();
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(appTitlebarToggleScript)

        if #available(macOS 26.0, *) {
            let glassHost = NSGlassEffectView(frame: webFrame)
            glassHost.style = .regular
            glassHost.cornerRadius = 0
            glassHost.tintColor = prePaintColor.withAlphaComponent(0.16)
            webViewHost = glassHost
        } else {
            let materialHost = NSVisualEffectView(frame: webFrame)
            materialHost.material = .underWindowBackground
            materialHost.blendingMode = .behindWindow
            materialHost.state = .active
            webViewHost = materialHost
        }
        webViewHost.autoresizingMask = [.width, .height]
        webView.frame = webViewHost.bounds
        webViewHost.addSubview(webView)
        contentView.addSubview(webViewHost)

        // Fix #64: install a thin transparent drag overlay over the title-bar zone.
        // Height 38px matches .app-titlebar in the web UI. The view is added AFTER
        // webView so it is on top in z-order, intercepting mouse events before WKWebView.
        let titleBarHeight: CGFloat = 38
        // Anchor to the top of contentView (y = bounds.height - 38 to bounds.height),
        // matching the web UI's .app-titlebar which fills the same zone.
        // Note: clMaxY (contentLayoutRect.maxY) is the BOTTOM of the native title bar —
        // using clMaxY - 38 would put the overlay ~28 px below the visual title bar zone.
        // The web title bar sits at the very top: y ∈ [bounds.height-38, bounds.height].
        let dragFrame = NSRect(x: 0, y: bounds.height - titleBarHeight, width: bounds.width, height: titleBarHeight)
        let dragView = TitleBarDragView(frame: dragFrame)
        dragView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(dragView)
        titleBarDragView = dragView

        // Always-visible "+" button in the title-bar drag zone (issue #75) —
        // gives single-window users a discoverable affordance for tabs
        // without relying on Cmd+T muscle-memory. Once AppKit's own tab bar
        // becomes visible (≥2 tabs in the group), updateAppTitlebarClass(tabbed:)
        // hides this button so we don't double up with AppKit's native "+".
        // Positioned at the right edge of the drag zone, vertically centered.
        // The SF Symbol "plus" image renders correctly in both .aqua and
        // .darkAqua and follows the system tint without manual repainting.
        // The SF Symbol "plus" is shipped with macOS 11+ (we target 12+) so
        // it always resolves. Defensive `?? NSImage()` keeps the type
        // signature happy without ever firing in practice.
        let plusImage = NSImage(systemSymbolName: "plus",
                                accessibilityDescription: "New Tab")
        let plusBtn = NSButton(image: plusImage ?? NSImage(),
                               target: nil,
                               action: #selector(AppDelegate.newBrowserTab))
        plusBtn.bezelStyle = .recessed
        plusBtn.isBordered = false
        plusBtn.toolTip = "New Tab (\u{2318}T)"
        plusBtn.translatesAutoresizingMaskIntoConstraints = false
        plusBtn.setAccessibilityLabel("New Tab")
        // target: nil routes the click through the responder chain — AppKit
        // walks firstResponder → window → app delegate, finding our @objc
        // newBrowserTab on AppDelegate. Avoids holding a hard reference to
        // NSApp.delegate and works correctly even if multiple AppDelegate
        // instances ever existed (they don't, but the pattern is safer).
        dragView.addSubview(plusBtn)
        NSLayoutConstraint.activate([
            plusBtn.trailingAnchor.constraint(equalTo: dragView.trailingAnchor, constant: -12),
            plusBtn.centerYAnchor.constraint(equalTo: dragView.centerYAnchor),
            plusBtn.widthAnchor.constraint(equalToConstant: 24),
            plusBtn.heightAnchor.constraint(equalToConstant: 22),
        ])
        newTabButton = plusBtn

        // Only add status bar in SSH mode
        if connectionMode == "ssh" {
            // Plain NSView with an explicit colour — we want the SSH footer to
            // match the page background EXACTLY, so the bottom edge reads as a
            // continuation of the page. An NSVisualEffectView would introduce
            // vibrancy that tints the colour off, breaking the visual seam.
            // The bar uses the fixed Mac canvas colour, matching the chat edge.
            let bar = NSView(
                frame: NSRect(x: 0, y: 0, width: bounds.width, height: statusBarHeight))
            bar.autoresizingMask = [.width]
            bar.wantsLayer = true
            bar.layer?.backgroundColor = Self.fixedCanvasColor.cgColor
            statusBar = bar
            contentView.addSubview(statusBar)

            separator = NSView(
                frame: NSRect(x: 0, y: statusBarHeight - 1, width: bounds.width, height: 1))
            separator.autoresizingMask = [.width]
            separator.wantsLayer = true
            // Resolve separatorColor in the fixed dark window appearance.
            window?.effectiveAppearance.performAsCurrentDrawingAppearance {
                separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
            }
            contentView.addSubview(separator)

            statusDot = NSView(frame: NSRect(x: 12, y: 9, width: 10, height: 10))
            statusDot.wantsLayer = true
            statusDot.layer?.cornerRadius = 5
            statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            statusBar.addSubview(statusDot)

            statusLabel = NSTextField(labelWithString: "Connecting…")
            statusLabel.font = NSFont.systemFont(ofSize: 11)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.frame = NSRect(x: 30, y: 6, width: 500, height: 16)
            statusBar.addSubview(statusLabel)

            reconnectButton = NSButton(
                title: "Reconnect", target: self, action: #selector(reconnectTapped))
            reconnectButton.bezelStyle = .rounded
            reconnectButton.font = NSFont.systemFont(ofSize: 11)
            reconnectButton.frame = NSRect(x: bounds.width - 110, y: 2, width: 100, height: 24)
            reconnectButton.autoresizingMask = [.minXMargin]
            reconnectButton.isHidden = true
            statusBar.addSubview(reconnectButton)
        }

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }

        // Start health polling for direct mode (fix #29)
        if connectionMode == "direct" {
            updateWindowTitle()
            startHealthCheck()
        }

        // Initial layout — typically a no-op (single window has no tab bar) but
        // catches the case where this controller's window gets created into an
        // existing tab group (rare, but possible during state restoration).
        updateWebViewLayout()
    }

    // MARK: - Paste

    /// Monotonically increasing counter used to disambiguate paste filenames
    /// when multiple screenshots are pasted in rapid succession. Combined with
    /// a millisecond timestamp this guarantees the WebUI's `addFiles()` keying
    /// (which dedupes by `f.name`) treats each paste as a distinct file even
    /// when two pastes land in the same millisecond. Reset behaviour is not
    /// needed: `UInt64` overflow takes ~584 years at 1 paste per nanosecond.
    private static var pasteSequence: UInt64 = 0

    func handlePaste() {
        let pb = NSPasteboard.general

        // Image paste — write to temp file and inject via fetch
        if let image = NSImage(pasteboard: pb),
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        {

            let base64 = png.base64EncodedString()

            // Each paste needs a unique filename — the WebUI's addFiles() helper
            // (static/ui.js) dedupes the pendingFiles array by `f.name`, so a
            // hardcoded "screenshot.png" silently drops the second and later
            // pastes when a user takes multiple screenshots in sequence and
            // pastes them one at a time. Combine a millisecond timestamp with a
            // monotonic counter so even back-to-back pastes within the same ms
            // get distinct names. The browser-side paste handler in
            // static/boot.js already uses an analogous suffix scheme; this
            // mirrors it for the Mac native paste path.
            Self.pasteSequence &+= 1
            let pasteTs = Int(Date().timeIntervalSince1970 * 1000)
            let uniqueName = "screenshot-\(pasteTs)-\(Self.pasteSequence).png"

            // Safe: base64 encoding only produces [A-Za-z0-9+/=], no JS-special chars.
            // The unique filename only contains digits and a hyphen, all
            // JS-string-safe — no escaping concerns when interpolated below.
            // Try multiple strategies to get the image into the web app
            let js = """
                (function() {
                    const base64 = '\(base64)';
                    const binary = atob(base64);
                    const bytes = new Uint8Array(binary.length);
                    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                    const blob = new Blob([bytes], { type: 'image/png' });
                    const file = new File([blob], '\(uniqueName)', { type: 'image/png', lastModified: Date.now() });

                    // Strategy 1: fire paste event on active element with clipboardData
                    const active = document.activeElement || document.body;
                    const dt = new DataTransfer();
                    dt.items.add(file);

                    // Override clipboardData getter so web app can read items
                    const pasteEvent = new Event('paste', { bubbles: true, cancelable: true });
                    Object.defineProperty(pasteEvent, 'clipboardData', {
                        value: dt,
                        writable: false
                    });
                    active.dispatchEvent(pasteEvent);

                    // Strategy 2: also try on document and body
                    document.dispatchEvent(new Event('paste', { bubbles: true }));

                    // Strategy 3: simulate drop on active element
                    const dropDt = new DataTransfer();
                    dropDt.items.add(file);
                    const rect = active.getBoundingClientRect();
                    const cx = rect.left + rect.width / 2;
                    const cy = rect.top + rect.height / 2;
                    ['dragenter','dragover','drop'].forEach(type => {
                        const ev = new DragEvent(type, {
                            bubbles: true,
                            cancelable: true,
                            clientX: cx,
                            clientY: cy,
                            dataTransfer: dropDt
                        });
                        active.dispatchEvent(ev);
                    });

                    return 'ok';
                })();
                """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("Paste JS error: \(error)")
                } else {
                    print("Paste JS result: \(result ?? "nil")")
                }
            }

        } else if let text = pb.string(forType: .string) {
            let jsonText: String
            if let data = try? JSONEncoder().encode(text),
                let encoded = String(data: data, encoding: .utf8)
            {
                jsonText = encoded
            } else {
                jsonText = "\"\""
            }
            webView.evaluateJavaScript(
                "document.execCommand('insertText', false, \(jsonText));",
                completionHandler: nil
            )
        } else {
            webView.evaluateJavaScript("document.execCommand('paste')", completionHandler: nil)
        }
    }

    // MARK: - Status

    // MARK: Health check (direct mode, fix #29)

    private func startHealthCheck() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.pingHealth()
        }
    }

    func stopHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pingHealth() {
        // Must be the ATS-free probe, not URLSession — ATS rejects plain-http
        // to non-loopback hosts, which would pin remote direct-mode URLs
        // (Tailscale/LAN) at "offline" regardless of actual server state.
        ReachabilityProbe.probeHealth(urlString: urlString, timeout: 5) { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self, state != self.healthState else { return }
                self.healthState = state
                self.updateWindowTitle()
            }
        }
    }

    private func updateWindowTitle() {
        // Update Dock badge first so it stays accurate even when the tab title
        // is fed from document.title (which doesn't carry health info). The
        // badge means "can't reach the server at all"; degraded /health only
        // shows in the title dot.
        (NSApp.delegate as? AppDelegate)?.setOfflineBadge(healthState == .unreachable)
        refreshTabTitle()
    }

    /// Compute and apply the tab/window title. Prefers `webView.title` (i.e.
    /// the active hermes-webui conversation's name) when available, truncated
    /// to fit a reasonable tab width. Falls back to "Hermes Agent  ● host" in
    /// direct mode (so health stays visible) or just "Hermes Agent" in SSH
    /// mode (the SSH status bar already surfaces host info).
    private func refreshTabTitle() {
        let raw = (webView?.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a redundant " — Hermes" / " - Hermes" / " | Hermes" suffix
        // (optionally " Agent"). hermes-webui sets document.title to
        // "<conversation> — Hermes"; we're already in the Hermes app, so
        // the brand suffix is just noise on a Mac tab. Handles em-dash,
        // hyphen, pipe, and middle-dot separators with surrounding whitespace.
        let suffixPattern = #"\s+[—\-|·]\s+Hermes(\s+Agent)?\s*$"#
        let pageTitle = raw.replacingOccurrences(
            of: suffixPattern,
            with: "",
            options: .regularExpression
        )
        let display: String
        if !pageTitle.isEmpty {
            display = pageTitle.count > 40
                ? String(pageTitle.prefix(38)) + "…"
                : pageTitle
        } else if connectionMode == "direct" {
            // ● /health verified · ◐ port answers, /health doesn't · ○ dead
            let dot: String
            switch healthState {
            case .healthy: dot = "●"
            case .reachable: dot = "◐"
            case .unreachable: dot = "○"
            }
            let host: String
            if let url = URL(string: urlString), let h = url.host {
                let port = url.port.map { ":\($0)" } ?? ""
                host = "\(h)\(port)"
            } else {
                host = urlString
            }
            display = "\(appTitle)  \(dot) \(host)"
        } else {
            display = appTitle
        }
        window?.title = display
    }

    func updateStatus(_ status: TunnelStatus, host: String, port: Int) {
        guard connectionMode == "ssh" else { return }

        DispatchQueue.main.async {
            switch status {
            case .connecting:
                self.statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
                self.statusLabel.stringValue = "Connecting…"
                self.reconnectButton.isHidden = true
            case .connected:
                self.statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
                self.statusLabel.stringValue = "Tunnel connected · \(host) · port \(port)"
                self.reconnectButton.isHidden = true
                (NSApp.delegate as? AppDelegate)?.setOfflineBadge(false)
            case .disconnected:
                self.statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
                self.statusLabel.stringValue = "Tunnel disconnected · click Reconnect to retry"
                self.reconnectButton.isHidden = false
                (NSApp.delegate as? AppDelegate)?.setOfflineBadge(true)
            }
        }
    }

    @objc func reconnectTapped() {
        onReconnect?()
    }

    // MARK: - WKScriptMessageHandler (notifications)

    private static let notificationLogger = Logger(
        subsystem: "ai.get-hermes.HermesAgent", category: "notifications")

    private static func logNotificationError(_ error: Error, operation: String) {
        let nsError = error as NSError
        notificationLogger.error(
            "\(operation) error domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
    }

    private func replyNotificationPermission(
        id: String?, granted: Bool, permission: String
    ) {
        guard let id else { return }
        let idJSON = (try? JSONEncoder().encode(id)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\""
        let permissionJSON = (try? JSONEncoder().encode(permission))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"default\""
        let script = "window.__hermesNativeNotificationReply && "
            + "window.__hermesNativeNotificationReply(\(idJSON), \(granted), \(permissionJSON));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func notificationPermissionName(
        _ status: UNAuthorizationStatus
    ) -> (granted: Bool, name: String) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return (true, "granted")
        case .denied:
            return (false, "denied")
        case .notDetermined:
            return (false, "default")
        @unknown default:
            return (false, "default")
        }
    }

    private func refreshNotificationStatus(replyID: String?) {
        let center = UNUserNotificationCenter.current()
        Self.notificationLogger.info("notificationStatus getSettings begin")
        center.getNotificationSettings { [weak self] settings in
            let status = self?.notificationPermissionName(settings.authorizationStatus)
                ?? (false, "default")
            Self.notificationLogger.info(
                "notificationStatus authorizationStatus=\(String(describing: settings.authorizationStatus), privacy: .public) permission=\(status.1, privacy: .public)")
            let granted = status.0
            let permission = status.1
            DispatchQueue.main.async(execute: DispatchWorkItem {
                self?.replyNotificationPermission(
                    id: replyID, granted: granted, permission: permission)
            })
        }
    }

    private func requestNotificationAuthorization(replyID: String?) {
        let center = UNUserNotificationCenter.current()
        Self.notificationLogger.info("requestAuthorization getSettings begin")
        center.getNotificationSettings { [weak self] settings in
            Self.notificationLogger.info(
                "requestAuthorization authorizationStatusBefore=\(String(describing: settings.authorizationStatus), privacy: .public)")
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.notificationLogger.info(
                    "requestAuthorization already granted status=\(String(describing: settings.authorizationStatus), privacy: .public)")
                DispatchQueue.main.async {
                    self?.replyNotificationPermission(
                        id: replyID, granted: true, permission: "granted")
                }
            case .denied:
                Self.notificationLogger.warning("requestAuthorization already denied")
                DispatchQueue.main.async {
                    self?.replyNotificationPermission(
                        id: replyID, granted: false, permission: "denied")
                }
            case .notDetermined:
                Self.notificationLogger.info("requestAuthorization requestAuthorization begin")
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        Self.logNotificationError(error, operation: "requestAuthorization")
                    }
                    Self.notificationLogger.info(
                        "requestAuthorization completed granted=\(granted, privacy: .public)")
                    center.getNotificationSettings { finalSettings in
                        let finalStatus = self?.notificationPermissionName(
                            finalSettings.authorizationStatus) ?? (false, "default")
                        Self.notificationLogger.info(
                            "requestAuthorization authorizationStatusAfter=\(String(describing: finalSettings.authorizationStatus), privacy: .public) permission=\(finalStatus.1, privacy: .public)")
                        DispatchQueue.main.async(execute: DispatchWorkItem {
                            self?.replyNotificationPermission(
                                id: replyID, granted: finalStatus.0,
                                permission: finalStatus.1)
                        })
                    }
                }
            @unknown default:
                Self.notificationLogger.warning("requestAuthorization unknown status")
                DispatchQueue.main.async {
                    self?.replyNotificationPermission(
                        id: replyID, granted: false, permission: "default")
                }
            }
        }
    }

    static func shouldSendNativeNotification(nativePreferenceEnabled: Bool, force: Bool) -> Bool {
        force || nativePreferenceEnabled
    }

    static func notificationIdentifier(
        title: String, sessionID: String?, fallbackID: String = UUID().uuidString
    ) -> String {
        let normalizedTitle = title.lowercased()
        let kind: String
        if normalizedTitle.contains("approval") {
            kind = "approval"
        } else if normalizedTitle.contains("clarification") {
            kind = "clarification"
        } else if normalizedTitle.contains("response") {
            kind = "response"
        } else {
            kind = "message"
        }
        let scope = sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackID
        return "hermes.\(kind).\(scope)"
    }

    private func sendNativeNotification(title: String, body: String, sessionID: String?) {
        let center = UNUserNotificationCenter.current()
        let addRequest: () -> Void = { [weak self] in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // Coalesce repeated events of the same kind within one session,
            // without allowing another tab or event type to overwrite it.
            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifier(title: title, sessionID: sessionID),
                content: content,
                trigger: nil
            )
            Self.notificationLogger.info(
                "center.add begin identifier=\(request.identifier, privacy: .public)")
            center.add(request) { error in
                if let error {
                    Self.logNotificationError(error, operation: "center.add")
                } else {
                    Self.notificationLogger.info("center.add completed")
                }
                _ = self
            }
        }

        Self.notificationLogger.info("send getSettings begin")
        center.getNotificationSettings { settings in
            Self.notificationLogger.info(
                "send authorizationStatus=\(String(describing: settings.authorizationStatus), privacy: .public)")
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                addRequest()
            case .notDetermined:
                Self.notificationLogger.info("send requestAuthorization begin")
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        Self.logNotificationError(error, operation: "send requestAuthorization")
                    }
                    Self.notificationLogger.info(
                        "send requestAuthorization completed granted=\(granted, privacy: .public)")
                    center.getNotificationSettings { finalSettings in
                        Self.notificationLogger.info(
                            "send authorizationStatusAfter=\(String(describing: finalSettings.authorizationStatus), privacy: .public)")
                        let finalStatus = self.notificationPermissionName(
                            finalSettings.authorizationStatus)
                        guard finalStatus.0 else {
                            Self.notificationLogger.warning(
                                "send skipped authorization status=\(String(describing: finalSettings.authorizationStatus), privacy: .public)")
                            return
                        }
                        addRequest()
                    }
                }
            case .denied:
                Self.notificationLogger.warning("send skipped authorization status=denied")
            @unknown default:
                Self.notificationLogger.warning(
                    "send skipped unknown authorization status=\(String(describing: settings.authorizationStatus), privacy: .public)")
            }
        }
    }

    /// Parse a CSS colour string (`rgb(...)`, `rgba(...)`, or `#RRGGBB`/`#RGB`)
    /// into normalised RGB components in [0, 1]. Returns nil on parse failure.
    static func parseCSSColor(_ css: String) -> (r: Double, g: Double, b: Double)? {
        let s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            func parseHex(_ str: Substring) -> Double? {
                guard let v = UInt8(str, radix: 16) else { return nil }
                return Double(v) / 255.0
            }
            if hex.count == 3 {
                guard let rr = parseHex(hex.prefix(1) + hex.prefix(1)),
                      let gg = parseHex(hex.dropFirst().prefix(1) + hex.dropFirst().prefix(1)),
                      let bb = parseHex(hex.dropFirst(2).prefix(1) + hex.dropFirst(2).prefix(1))
                else { return nil }
                return (rr, gg, bb)
            }
            if hex.count == 6 {
                guard let rr = parseHex(hex.prefix(2)),
                      let gg = parseHex(hex.dropFirst(2).prefix(2)),
                      let bb = parseHex(hex.dropFirst(4).prefix(2))
                else { return nil }
                return (rr, gg, bb)
            }
            return nil
        }
        if s.hasPrefix("rgb") {
            let inside = s.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
            let parts = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3,
                  let rr = Double(parts[0]),
                  let gg = Double(parts[1]),
                  let bb = Double(parts[2])
            else { return nil }
            return (rr / 255, gg / 255, bb / 255)
        }
        return nil
    }

    /// Whether a CSS colour falls in the "dark" half by perceived luminance.
    /// Returns true (dark) on parse failure so we err on the side of preserving
    /// the dark-by-default look.
    static func cssColorIsDark(_ css: String) -> Bool {
        guard let rgb = parseCSSColor(css) else { return true }
        // WCAG-ish relative luminance (linear approximation, good enough to bisect).
        let luminance = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
        return luminance < 0.5
    }

    /// Format an NSColor as a #RRGGBB hex string suitable for embedding in a
    /// CSS string. Forces sRGB so the components round-trip cleanly regardless
    /// of the colour space the receiver was constructed in.
    static func hexString(for color: NSColor) -> String {
        let sRGB = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(max(0, min(1, Double(sRGB.redComponent))) * 255))
        let g = Int(round(max(0, min(1, Double(sRGB.greenComponent))) * 255))
        let b = Int(round(max(0, min(1, Double(sRGB.blueComponent))) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Theme bridge: WebUI reports its exact page colour, persisted theme
        // mode, and skin. Skin is independent because accent-only changes can
        // leave the background unchanged while still requiring tab sync.
        if message.name == "hermesTheme" {
            let css: String?
            let themeMode: String?
            let skin: String?
            if let body = message.body as? [String: Any] {
                css = body["background"] as? String
                themeMode = body["theme"] as? String
                skin = body["skin"] as? String
            } else {
                css = message.body as? String
                themeMode = nil
                skin = nil
            }
            guard let css, let rgb = Self.parseCSSColor(css) else { return }
            let luminance = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
            let appearance = themeMode.map { AppDelegate.appearanceForThemeMode($0) }
                ?? AppDelegate.appearanceForLuminance(luminance)
            let bgColor = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
            (NSApp.delegate as? AppDelegate)?.updateAppearance(
                appearance, backgroundColor: bgColor, themeMode: themeMode, skin: skin)
            return
        }
        guard message.name == "hermesNotify" else { return }
        let body = message.body as? [String: Any]
        let type = body?["type"] as? String
        Self.notificationLogger.info(
            "received message name=\(message.name, privacy: .public) type=\(type ?? "missing", privacy: .public)")
        guard let body, let type else {
            Self.notificationLogger.warning("received malformed hermesNotify message")
            return
        }

        switch type {
        case "requestAuthorization":
            requestNotificationAuthorization(replyID: body["id"] as? String)
        case "notificationStatus":
            refreshNotificationStatus(replyID: body["id"] as? String)
        case "send":
            guard let title = body["title"] as? String,
                  let text = body["body"] as? String
            else { return }
            let force = body["force"] as? Bool ?? false
            guard Self.shouldSendNativeNotification(
                nativePreferenceEnabled: UserDefaults.standard.bool(forKey: "notificationsEnabled"),
                force: force
            ) else {
                Self.notificationLogger.info("send skipped native preference disabled")
                return
            }
            sendNativeNotification(
                title: title, body: text, sessionID: body["sid"] as? String)
        default:
            Self.notificationLogger.warning("unknown bridge message type=\(type, privacy: .public)")
        }
    }

    private func handleEffectiveAppearanceChange() {
        guard (NSApp.delegate as? AppDelegate)?.currentThemeMode == "system" else { return }
        // AppKit already repaints the native chrome because the window inherits
        // its appearance. Re-apply the WebUI system listener as well, so the
        // WKWebView updates immediately even when WebKit delays its media-query
        // notification during a macOS appearance transition.
        webView.evaluateJavaScript(
            "if (typeof _applyTheme === 'function') _applyTheme('system');",
            completionHandler: nil
        )
        reportCurrentThemeToNative()
    }

    /// Called by AppDelegate's application-level appearance notification.
    func systemAppearanceDidChange() {
        guard (NSApp.delegate as? AppDelegate)?.currentThemeMode == "system" else { return }
        window?.appearance = NSAppearance(named: .darkAqua)
        handleEffectiveAppearanceChange()
    }

    private func setWebUIBackgrounded(_ backgrounded: Bool) {
        guard webView != nil else { return }
        webView.evaluateJavaScript(
            "window.__hermesNativeBackgrounded = \(backgrounded ? "true" : "false");"
                + "if (typeof window.__hermesSetBackgrounded === 'function') "
                + "window.__hermesSetBackgrounded(window.__hermesNativeBackgrounded);",
            completionHandler: nil
        )
    }

    // MARK: - Zoom level restore (fix #43) + startup fade-in (fix #52)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Fix #52: fade the window in on the very first successful paint.
        // Uses a bool flag (not alphaValue check) to be robust against any
        // intermediate alpha changes. Subsequent navigations (SPA routes,
        // Cmd+R reloads) see hasCompletedFirstPaint=true and skip the animation.
        if !hasCompletedFirstPaint {
            hasCompletedFirstPaint = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window?.animator().alphaValue = 1
            }
        }

        // Synchronize the native cache immediately with the WebUI's persisted
        // theme. This avoids leaving a stale light/dark window appearance in
        // place while the pixel-sampling stability timer is waiting.
        reportCurrentThemeToNative()

        // Fix #57: refine traffic light clearance to exact measured value.
        injectTrafficLightWidthVar()

        // Restore persisted zoom level. double(forKey:) returns 0.0 when unset —
        // treat any value outside the valid zoom range as "no preference".
        let saved = UserDefaults.standard.double(forKey: AppDelegate.zoomKey)
        if saved >= 0.5 && saved <= 3.0 {
            webView.pageZoom = saved
        }

        // Apply tabbed-mode titlebar class on first paint and SPA navigations —
        // covers the case where the page loaded in a window already in a tab group,
        // or where a route change re-rendered the body without firing the
        // tabbedWindows KVO observer.
        let tabbed = window?.tabGroup?.isTabBarVisible ?? false
        updateAppTitlebarClass(tabbed: tabbed)
        setWebUIBackgrounded(!(window?.isKeyWindow ?? false))
    }

    private func reportCurrentThemeToNative() {
        webView.evaluateJavaScript(
            """
            (function() {
                try {
                    var theme = (localStorage.getItem('hermes-theme') || 'dark').toLowerCase();
                    if (!['light', 'dark', 'system'].includes(theme)) theme = 'dark';
                    var skin = (document.documentElement.dataset.skin || 'default').toLowerCase();
                    var meta = document.getElementById('hermes-theme-color');
                    var background = meta && meta.getAttribute('content');
                    if (background && window.webkit && window.webkit.messageHandlers
                        && window.webkit.messageHandlers.hermesTheme) {
                        window.webkit.messageHandlers.hermesTheme.postMessage({
                            background: background,
                            theme: theme,
                            skin: skin
                        });
                    }
                } catch (_) {}
            })();
            """,
            completionHandler: nil
        )
    }

    /// Measures the actual right edge of the zoom (green) traffic light button and
    /// injects it as --traffic-light-width CSS custom property so the web title bar
    /// leaves correct clearance. Called after first paint and fullscreen transitions.
    private func injectTrafficLightWidthVar() {
        let reserve: CGFloat
        if let zoom = window?.standardWindowButton(.zoomButton) {
            // .frame is in NSThemeFrame coords = window-space in the title-bar strip.
            reserve = zoom.frame.maxX + 12
        } else {
            reserve = 80
        }
        let px = Int(reserve)
        webView.evaluateJavaScript(
            "document.documentElement.style.setProperty('--traffic-light-width', '\(px)px');",
            completionHandler: nil
        )
    }

    // MARK: - Navigation failure

    // If the main-frame load can't reach hermes (server went away, tunnel
    // dropped mid-session), bail back to the small native error window rather
    // than painting an error page inside a full-size WebView.
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        // Fix #52: ensure the window is visible before we close/replace it.
        // If the very first navigation fails, didFinishNavigation never fires,
        // so the window stays at alphaValue=0. Restore it so the error window
        // transition isn't invisible.
        window?.alphaValue = 1
        let nsError = error as NSError
        // NSURLErrorCancelled fires for link clicks we redirected to Safari —
        // those aren't real failures, ignore them.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        guard !didReportNavigationFailure else { return }
        didReportNavigationFailure = true
        onNavigationFailed?()
    }

    // Server reachable but returned 5xx — the network preflight can't catch
    // this since it only checks that *some* HTTP response came back. Surface
    // it through the same native error window as a network failure.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            if httpResponse.statusCode >= 500 {
                decisionHandler(.cancel)
                guard !didReportNavigationFailure else { return }
                didReportNavigationFailure = true
                onNavigationFailed?()
                return
            }
            let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            if disposition.lowercased().hasPrefix("attachment") || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - File upload

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: self.window!) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: - Navigation guard (issue #7)
    // Allow only localhost/127.0.0.1 navigation. All other http/https links open in
    // Safari. file:// is blocked entirely.

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // An HTML download attribute becomes a navigation action before a
        // response is available. Handle it before the generic API guard below;
        // Hermes WebUI artifact links use /api/media and would otherwise be
        // cancelled before WKWebView can create a WKDownload. file:// is
        // excluded: a download-attributed file:// link must fall through to
        // the scheme guard below and be cancelled, never become a WKDownload
        // of a local file. blob:/data: stay eligible — they carry
        // page-authored content, and JS-generated exports rely on them.
        if navigationAction.shouldPerformDownload, url.scheme?.lowercased() != "file" {
            decisionHandler(.download)
            return
        }

        // Defense-in-depth (#76): API endpoints should never become full-page
        // navigations. The WebUI's JS treats /api/* as fetch targets only, and
        // every API error response uses the JSON shape `{"error": "..."}` —
        // if a navigation lands on an API URL (e.g., during a post-update
        // restart race where `location.reload()` from `_waitForServerThenReload()`
        // intercepts a 404 from the partially-rebuilt route table), the
        // WKWebView would render the JSON body as the entire page. Cancelling
        // here keeps the previous page state visible and gives the user a
        // chance to retry the action. Companion WebUI-side fix at
        // nesquena/hermes-webui#1835 locks down the home route to never
        // return JSON; this Mac-side guard catches every other class of
        // accidental API navigation regardless of WebUI state. The explicit
        // artifact endpoints remain eligible for response-time download
        // detection via Content-Disposition.
        let downloadAPIPaths = ["/api/media", "/api/file/raw", "/api/folder/download"]
        if url.path.hasPrefix("/api/") && !downloadAPIPaths.contains(url.path) {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // Block file:// entirely
        if scheme == "file" {
            decisionHandler(.cancel)
            return
        }

        // Allow non-http(s) schemes (about:, blob:, data:, etc.) — WebKit needs these internally
        guard scheme == "http" || scheme == "https" else {
            decisionHandler(.allow)
            return
        }

        let host = url.host?.lowercased() ?? ""

        // Allow localhost and loopback
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            decisionHandler(.allow)
            return
        }

        // Allow navigation to the configured remote host (SSH mode)
        let configuredURL = UserDefaults.standard.string(forKey: "targetURL") ?? ""
        if let configuredHost = URL(string: configuredURL)?.host?.lowercased(),
            !configuredHost.isEmpty,
            host == configuredHost
        {
            decisionHandler(.allow)
            return
        }

        // Everything else opens in Safari
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    // MARK: - Window close / hide (Cmd+W hides, doesn't quit)

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Multi-window (#42): only the LAST live browser window hides on Cmd+W —
        // closing it for real would kill the Dock icon and force a relaunch.
        // For non-last windows, let AppKit close normally so windowWillClose fires
        // and AppDelegate prunes its browserWindows array (without that, closed
        // tabs leak as phantoms in the array and menu actions misroute to a dead
        // controller). Tab drag-out close, Cmd+W in any non-last window, and the
        // tab close button all hit this path.
        let appDelegate = NSApp.delegate as? AppDelegate
        let liveCount = appDelegate?.browserWindows.count ?? 0
        if liveCount <= 1 {
            // Last window: hide instead of close so the app stays alive in the Dock.
            // Cmd+N from there falls through to startTunnel() if needed.
            window?.orderOut(nil)
            return false
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure the WebView holds keyboard focus whenever the window is active,
        // so shortcuts like Cmd+K reach JavaScript without requiring an extra click.
        webView.becomeFirstResponder()
        setWebUIBackgrounded(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        setWebUIBackgrounded(true)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        setWebUIBackgrounded(true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        setWebUIBackgrounded(!(window?.isKeyWindow ?? false))
    }

    // MARK: - Tab-bar-aware layout

    /// Resize webView so the tab bar (when present) doesn't clip the web app's
    /// top content. With .fullSizeContentView, contentView extends to the top of
    /// the window, which means webView's top sits in the same vertical zone as
    /// AppKit's tab bar. When more than one tab is in the group, AppKit shows
    /// the bar — at which point we pin webView's top to contentLayoutRect.maxY
    /// (the bottom of the title-bar+tab-bar strip) so the web's `.app-titlebar`
    /// renders just below the tab bar instead of behind it.
    /// When the tab bar is absent (single-tab/standalone), we extend webView all
    /// the way to bounds.height so the v1.5.0 "web titlebar under transparent
    /// title bar" look is preserved.
    func updateWebViewLayout() {
        guard let win = window, let contentView = win.contentView, webView != nil else { return }
        // Use NSWindowTabGroup.isTabBarVisible — it's true for ≥2 tabs in the group
        // AND for the explicit Window → Show Tab Bar case with a single window (the
        // raw tabbedWindows.count > 1 check missed the latter, leaving the AppKit
        // bar to clip web content when a user manually requested it). macOS 10.13+,
        // we target 12+.
        let tabBarVisible = win.tabGroup?.isTabBarVisible ?? false
        let statusBarHeight: CGFloat = connectionMode == "ssh" ? 28 : 0
        // Fix #68: when the find bar is open, reserve its 36 px at the top.
        // Without this, recomputes triggered by windowDidResize, fullscreen
        // transitions, or the tabbedWindows KVO observer would grow webView
        // back over the find bar — hiding the search field while the bar
        // remained in the view hierarchy. The find bar's own frame is anchored
        // to contentLayoutRect.maxY - barHeight, so it follows the title-bar
        // zone correctly across all these transitions; only webView height
        // needs the carve-out here.
        let findBarHeight: CGFloat = findBarVisible ? 36 : 0
        let topY: CGFloat = tabBarVisible
            ? win.contentLayoutRect.maxY - findBarHeight
            : contentView.bounds.height - findBarHeight
        let newHeight = max(0, topY - statusBarHeight)
        webViewHost.frame = NSRect(
            x: 0, y: statusBarHeight,
            width: contentView.bounds.width, height: newHeight)
        webView.frame = webViewHost.bounds
        // Hide the web titlebar when the AppKit tab bar is rendering it
        // redundantly; restore when it's gone.
        updateAppTitlebarClass(tabbed: tabBarVisible)
    }

    /// Toggle a class on `<body>` that hides the web app's `.app-titlebar` element
    /// when AppKit is rendering its native tab bar. The CSS rule is registered as
    /// a documentStart user script in `buildUI`. Called from `updateWebViewLayout`
    /// (covers tab join/leave, fullscreen, resize) and from `didFinish` (catches
    /// initial page load and SPA navigations where the body might be re-rendered).
    private func updateAppTitlebarClass(tabbed: Bool) {
        guard webView != nil else { return }
        let action = tabbed ? "add" : "remove"
        webView.evaluateJavaScript(
            "if (document.body) document.body.classList.\(action)('hermes-mac-tabbed');",
            completionHandler: nil
        )
        // Issue #75: hide our "+" button when AppKit's native tab bar is
        // visible (it provides its own "+"). When the tab bar is hidden
        // (single-window state), our button is the only discoverable
        // affordance for opening a new tab, so it stays visible.
        newTabButton?.isHidden = tabbed
    }

    func windowDidResize(_ notification: Notification) {
        // Window resize can also change contentLayoutRect (e.g. fullscreen toggle
        // mid-resize). Recompute the tab-bar-aware webView frame on every resize.
        updateWebViewLayout()
    }

    /// Refresh native chrome after a WebUI theme event. The reported colour is
    /// intentionally ignored: the Mac wrapper owns one fixed canvas/tint while
    /// the WebUI preference continues to persist and sync across tabs.
    func applyChromeBackgroundColor(_ color: NSColor) {
        _ = color  // WebUI still reports its preference; native chrome stays fixed.
        let fixedColor = Self.fixedCanvasColor
        statusBar?.layer?.backgroundColor = fixedColor.cgColor
        if #available(macOS 26.0, *), let glassHost = webViewHost as? NSGlassEffectView {
            glassHost.tintColor = fixedColor.withAlphaComponent(0.16)
        }
        // Re-resolve the separator colour in the new appearance so its tone
        // matches the surroundings (1-px line, but still nice to keep crisp).
        if let sep = separator {
            window?.effectiveAppearance.performAsCurrentDrawingAppearance {
                sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
            }
        }
    }

    // MARK: - Full-screen state persistence (fix #43)

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "windowWasFullScreen")
        // Fix #57: in fullscreen the traffic lights are gone; reset clearance to 0.
        webView.evaluateJavaScript(
            "document.documentElement.style.setProperty('--traffic-light-width', '0px');",
            completionHandler: nil
        )
        // Fullscreen toggles the tab bar's visibility too — recompute layout.
        updateWebViewLayout()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // Don't clobber the saved preference during a programmatic reconnect close.
        guard !isIntentionalClose else { return }
        // Multi-window (#42): only persist false when no OTHER browser window is
        // currently fullscreen. Without this guard, exiting fullscreen on one window
        // while others remain fullscreen would forget the preference, and on next
        // launch no window would restore to fullscreen even though one had been.
        let appDelegate = NSApp.delegate as? AppDelegate
        let othersFullScreen = appDelegate?.browserWindows.contains { other in
            other !== self && (other.window?.styleMask.contains(.fullScreen) ?? false)
        } ?? false
        if !othersFullScreen {
            UserDefaults.standard.set(false, forKey: "windowWasFullScreen")
        }
        // Fix #57: restore traffic light clearance after exiting fullscreen.
        injectTrafficLightWidthVar()
        // Tab bar visibility may have changed across the fullscreen transition.
        updateWebViewLayout()
    }

    // MARK: - Reconnect in place (fix #10)

    /// Reconnect without destroying the WKWebView, preserving cookies,
    /// localStorage, IndexedDB, and scroll position. Called by AppDelegate
    /// when a reconnect is needed and the window is still alive.
    func reconnectInPlace(targetURL newURLString: String) {
        // Reset dedup flag so a real failure on this attempt routes to error window.
        didReportNavigationFailure = false
        // Defensive: ensures windowDidExitFullScreen doesn't no-op after reconnect.
        isIntentionalClose = false
        // Stop in-flight provisional load to prevent zombie didFailProvisionalNavigation.
        webView.stopLoading()
        let sameURL = (newURLString == urlString)
        if sameURL {
            webView.reload()
        } else {
            urlString = newURLString
            if let url = URL(string: newURLString) {
                webView.load(URLRequest(url: url))
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopHealthCheck()
        hideFindBar()
        // Notify AppDelegate so it can prune its browserWindows array. We pass self
        // so the delegate can match by identity. This fires for: user-initiated close
        // (Cmd+W on a window that's not the last), tab drag-out close, programmatic
        // close from AppDelegate (via isIntentionalClose=true in startTunnel), and
        // app termination. AppDelegate handles all four uniformly — array removal
        // is idempotent.
        onWindowWillClose?(self)
    }

    // MARK: - Find in page (fix #37/#45, Cmd+F)
    // Uses window.find() JS (macOS 12+ via WKWebView.evaluateJavaScript) with a
    // native NSSearchField overlay. NSTextFinder bridging would give a more
    // native look but requires implementing NSTextFinderClient over a WebView —
    // not worth the complexity for a thin wrapper app.

    private func toggleFindBar() {
        if findBarVisible {
            hideFindBar()
        } else {
            showFindBar()
        }
    }

    private func showFindBar() {
        guard findBar == nil, let contentView = window?.contentView else { return }
        findBarVisible = true

        let barHeight: CGFloat = 36
        // Fix #57 interaction: with .fullSizeContentView the contentView extends under
        // the title bar. Use contentLayoutRect (the area BELOW the title bar) so the
        // find bar anchors below the traffic lights, not behind them.
        let layoutTop = window.map { $0.contentLayoutRect.maxY } ?? contentView.bounds.height
        let bar = NSVisualEffectView(frame: NSRect(
            x: 0, y: layoutTop - barHeight,
            width: contentView.bounds.width, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.blendingMode = .withinWindow
        bar.material = .headerView  // .titlebar is deprecated; .headerView is the modern equivalent
        bar.state = .active
        contentView.addSubview(bar)
        findBar = bar

        let field = NSSearchField(frame: NSRect(x: 8, y: 5, width: 220, height: 24))
        field.placeholderString = "Find in page…"
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(findFieldChanged(_:))
        bar.addSubview(field)
        findField = field

        let prevBtn = NSButton(title: "\u{2039}", target: self, action: #selector(findPrevTapped))
        prevBtn.bezelStyle = .rounded
        prevBtn.font = NSFont.systemFont(ofSize: 15)
        prevBtn.frame = NSRect(x: 234, y: 4, width: 28, height: 26)
        bar.addSubview(prevBtn)

        let nextBtn = NSButton(title: "\u{203A}", target: self, action: #selector(findNextTapped))
        nextBtn.bezelStyle = .rounded
        nextBtn.font = NSFont.systemFont(ofSize: 15)
        nextBtn.frame = NSRect(x: 264, y: 4, width: 28, height: 26)
        bar.addSubview(nextBtn)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(findDoneTapped))
        doneBtn.bezelStyle = .rounded
        doneBtn.font = NSFont.systemFont(ofSize: 12)
        doneBtn.frame = NSRect(x: 298, y: 4, width: 52, height: 26)
        bar.addSubview(doneBtn)

        // Shrink webView to make room for the bar
        webView.frame.size.height -= barHeight
        window?.makeFirstResponder(field)
    }

    private func hideFindBar() {
        guard let bar = findBar else { return }
        findBarVisible = false
        bar.removeFromSuperview()
        findBar = nil
        findField = nil
        // Restore webView to its normal frame (below title bar, above status bar)
        if let win = window, let contentView = win.contentView {
            let statusBarHeight: CGFloat = connectionMode == "ssh" ? 28 : 0
            let layoutTop = win.contentLayoutRect.maxY
            webView.frame = NSRect(
                x: 0, y: statusBarHeight,
                width: contentView.bounds.width,
                height: layoutTop - statusBarHeight)
        }
        window?.makeFirstResponder(webView)
    }

    // cancelOperation is sent by AppKit when the user presses Escape.
    // Only act when the find bar is open — swallow it otherwise so Escape
    // doesn't bubble up to NSWindow.performClose and hide the window.
    override func cancelOperation(_ sender: Any?) {
        if findBarVisible {
            hideFindBar()
        }
    }

    @objc private func findFieldChanged(_ sender: NSSearchField) {
        runFind(query: sender.stringValue, forward: true)
    }

    @objc private func findNextTapped() { findNext(forward: true) }
    @objc private func findPrevTapped() { findNext(forward: false) }
    @objc private func findDoneTapped() { hideFindBar() }

    private func findNext(forward: Bool) {
        guard let q = findField?.stringValue, !q.isEmpty else {
            if !findBarVisible { showFindBar() }
            return
        }
        runFind(query: q, forward: forward)
    }

    private func runFind(query: String, forward: Bool) {
        guard !query.isEmpty else { return }
        // window.find(aString, caseSensitive, backwards, wrapAround, wholeWord, searchInFrames, showDialog)
        // Escape backslashes and single-quotes to make the query safe inside the JS string literal.
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let backwards = forward ? "false" : "true"
        let js = "window.find('\(escaped)', false, \(backwards), true, false, true, false);"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Microphone / camera permissions

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let mediaType: AVMediaType = (type == .camera) ? .video : .audio
        // Always route through requestAccess — never short-circuit on .authorized.
        // requestAccess sends an XPC message to tccd on every call, which is required
        // for WebContent's capture attribution to succeed. Short-circuiting to
        // decisionHandler(.grant) when .authorized bypasses this tccd round-trip,
        // causing getUserMedia() to fail with NotAllowedError even when TCC is .authorized.
        // When already .authorized, requestAccess completes immediately (no UI, no prompt).
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            DispatchQueue.main.async {
                decisionHandler(granted ? .grant : .deny)
                // Show a recovery alert for mic denial — once per session, not for camera.
                guard !granted, type != .camera,
                      !Self.didShowMicDeniedAlert else { return }
                Self.didShowMicDeniedAlert = true
                let alert = NSAlert()
                alert.messageText = "Microphone Access Required"
                alert.informativeText = "Enable microphone access for Hermes Agent in System Settings \u{2192} Privacy & Security \u{2192} Microphone, then reload the page."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - WKDownloadDelegate

extension BrowserWindowController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        guard let win = window else {
            completionHandler(nil)
            return
        }
        panel.beginSheetModal(for: win) { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {}

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async { [weak self] in
            guard let win = self?.window else { return }
            let alert = NSAlert()
            alert.messageText = "Download Failed"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: win)
        }
    }
}
