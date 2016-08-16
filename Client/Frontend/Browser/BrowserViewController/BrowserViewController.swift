/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit
import WebKit
import Shared
import Storage
import SnapKit
import XCGLogger
import Account
import ReadingList
import MobileCoreServices

private let log = Logger.browserLogger


struct BrowserViewControllerUX {
    static let BackgroundColor = UIConstants.AppBackgroundColor
    static let ShowHeaderTapAreaHeight: CGFloat = 32
    static let BookmarkStarAnimationDuration: Double = 0.5
    static let BookmarkStarAnimationOffset: CGFloat = 80
}

class BrowserViewController: UIViewController {
    var homePanelController: HomePanelViewController?
    var webViewContainer: UIView!
    var urlBar: URLBarView!
    var readerModeBar: ReaderModeBarView?
    var readerModeCache: ReaderModeCache
    var statusBarOverlay: UIView!
    private(set) var toolbar: BraveBrowserBottomToolbar?
    var searchController: SearchViewController?
    var screenshotHelper: ScreenshotHelper!
    var homePanelIsInline = true
    var searchLoader: SearchLoader!
    let snackBars = UIView()
    let webViewContainerToolbar = UIView()
    var findInPageBar: FindInPageBar?
    let findInPageContainer = UIView()

    // popover rotation handling
    var displayedPopoverController: UIViewController?
    var updateDisplayedPopoverProperties: (() -> ())?

    var openInHelper: OpenInHelper?

    // location label actions
    var pasteGoAction: AccessibleAction!
    var pasteAction: AccessibleAction!
    var copyAddressAction: AccessibleAction!

    weak var tabTrayController: TabTrayController!

    let profile: Profile
    let tabManager: TabManager

    // These views wrap the urlbar and toolbar to provide background effects on them
    var header: BlurWrapper!
    var headerBackdrop: UIView!
    var footer: UIView!
    var footerBackdrop: UIView!
    var footerBackground: BlurWrapper?
    var topTouchArea: UIButton!

    // Backdrop used for displaying greyed background for private tabs
    var webViewContainerBackdrop: UIView!

    var scrollController = BraveScrollController()

    private var keyboardState: KeyboardState?

    let WhiteListedUrls = ["\\/\\/itunes\\.apple\\.com\\/"]

    // Tracking navigation items to record history types.
    // TODO: weak references?
    var ignoredNavigation = Set<WKNavigation>()
    var typedNavigation = [WKNavigation: VisitType]()
    var navigationToolbar: BrowserToolbarProtocol {
        return toolbar ?? urlBar
    }

    static var instanceAsserter = 0 // Brave: it is easy to get confused as to which fx classes are effectively singletons

    init(profile: Profile, tabManager: TabManager) {
        self.profile = profile
        self.tabManager = tabManager
        self.readerModeCache = DiskReaderModeCache.sharedInstance
        super.init(nibName: nil, bundle: nil)
        didInit()

        BrowserViewController.instanceAsserter += 1
        assert(BrowserViewController.instanceAsserter == 1)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectedTabChanged(selected: Browser) {}

    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
            return UIInterfaceOrientationMask.AllButUpsideDown
        } else {
            return UIInterfaceOrientationMask.All
        }
    }

    override func viewWillTransitionToSize(size: CGSize, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransitionToSize(size, withTransitionCoordinator: coordinator)

        displayedPopoverController?.dismissViewControllerAnimated(true, completion: nil)

        guard let displayedPopoverController = self.displayedPopoverController else {
            return
        }

        coordinator.animateAlongsideTransition(nil) { context in
            self.updateDisplayedPopoverProperties?()
            self.presentViewController(displayedPopoverController, animated: true, completion: nil)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        log.debug("BVC received memory warning")
    }

    private func didInit() {
        screenshotHelper = ScreenshotHelper(controller: self)
        tabManager.addDelegate(self)
        tabManager.addNavigationDelegate(self)
    }

    override func preferredStatusBarStyle() -> UIStatusBarStyle {
        return UIStatusBarStyle.LightContent
    }

    func shouldShowFooterForTraitCollection(previousTraitCollection: UITraitCollection) -> Bool {
        return previousTraitCollection.verticalSizeClass != .Compact &&
               previousTraitCollection.horizontalSizeClass != .Regular
    }


    func toggleSnackBarVisibility(show show: Bool) {
        if show {
            UIView.animateWithDuration(0.1, animations: { self.snackBars.hidden = false })
        } else {
            snackBars.hidden = true
        }
    }

    func updateToolbarStateForTraitCollection(newCollection: UITraitCollection) {
        let showToolbar = shouldShowFooterForTraitCollection(newCollection)

        urlBar.setShowToolbar(!showToolbar)
        toolbar?.removeFromSuperview()
        toolbar?.browserToolbarDelegate = nil
        footerBackground?.removeFromSuperview()
        footerBackground = nil
        toolbar = nil

        if showToolbar {
            toolbar = BraveBrowserBottomToolbar()
            toolbar?.browserToolbarDelegate = self
            footerBackground = BlurWrapper(view: toolbar!)
            footerBackground?.translatesAutoresizingMaskIntoConstraints = false

#if !BRAVE
            // Need to reset the proper blur style
            if let selectedTab = tabManager.selectedTab where selectedTab.isPrivate {
                footerBackground!.blurStyle = .Dark
            }
#else
            footerBackground!.blurStyle = .Dark
#endif
            footer.addSubview(footerBackground!)
        }

        view.setNeedsUpdateConstraints()
        if let home = homePanelController {
            home.view.setNeedsUpdateConstraints()
        }

        if let tab = tabManager.selectedTab,
               webView = tab.webView {
            updateURLBarDisplayURL(tab)
            navigationToolbar.updateBackStatus(webView.canGoBack)
            navigationToolbar.updateForwardStatus(webView.canGoForward)
            navigationToolbar.updateReloadStatus(tab.loading ?? false)
        }
    }

    override func willTransitionToTraitCollection(newCollection: UITraitCollection, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransitionToTraitCollection(newCollection, withTransitionCoordinator: coordinator)

        // During split screen launching on iPad, this callback gets fired before viewDidLoad gets a chance to
        // set things up. Make sure to only update the toolbar state if the view is ready for it.
        if isViewLoaded() {
            updateToolbarStateForTraitCollection(newCollection)
        }

        displayedPopoverController?.dismissViewControllerAnimated(true, completion: nil)

        // WKWebView looks like it has a bug where it doesn't invalidate it's visible area when the user
        // performs a device rotation. Since scrolling calls
        // _updateVisibleContentRects (https://github.com/WebKit/webkit/blob/master/Source/WebKit2/UIProcess/API/Cocoa/WKWebView.mm#L1430)
        // this method nudges the web view's scroll view by a single pixel to force it to invalidate.
        if let scrollView = self.tabManager.selectedTab?.webView?.scrollView {
            let contentOffset = scrollView.contentOffset
            coordinator.animateAlongsideTransition({ context in
                scrollView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + 1), animated: true)
                self.scrollController.showToolbars(animated: false)
            }, completion: { context in
                scrollView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y), animated: false)
            })
        }
    }

    func SELappDidEnterBackgroundNotification() {
        displayedPopoverController?.dismissViewControllerAnimated(false, completion: nil)
    }

    func SELtappedTopArea() {
        scrollController.showToolbars(animated: true)
    }

    func SELappWillResignActiveNotification() {
        // If we are displying a private tab, hide any elements in the browser that we wouldn't want shown
        // when the app is in the home switcher
        guard let privateTab = tabManager.selectedTab where privateTab.isPrivate else {
            return
        }

        webViewContainerBackdrop.alpha = 1
        webViewContainer.alpha = 0
        urlBar.locationView.alpha = 0
    }

    func SELappDidBecomeActiveNotification() {
        // Re-show any components that might have been hidden because they were being displayed
        // as part of a private mode tab
        UIView.animateWithDuration(0.2, delay: 0, options: UIViewAnimationOptions.CurveEaseInOut, animations: {
            self.webViewContainer.alpha = 1
            self.urlBar.locationView.alpha = 1
            self.view.backgroundColor = UIColor.clearColor()
        }, completion: { _ in
            self.webViewContainerBackdrop.alpha = 0
        })
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: BookmarkStatusChangedNotification, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillResignActiveNotification, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillEnterForegroundNotification, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationDidEnterBackgroundNotification, object: nil)
    }

    override func viewDidLoad() {
        log.debug("BVC viewDidLoad…")
        super.viewDidLoad()
        log.debug("BVC super viewDidLoad called.")
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BrowserViewController.SELBookmarkStatusDidChange(_:)), name: BookmarkStatusChangedNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BrowserViewController.SELappWillResignActiveNotification), name: UIApplicationWillResignActiveNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BrowserViewController.SELappDidBecomeActiveNotification), name: UIApplicationDidBecomeActiveNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BrowserViewController.SELappDidEnterBackgroundNotification), name: UIApplicationDidEnterBackgroundNotification, object: nil)
        KeyboardHelper.defaultHelper.addDelegate(self)

        log.debug("BVC adding footer and header…")
        footerBackdrop = UIView()
        footerBackdrop.backgroundColor = UIColor.whiteColor()
        view.addSubview(footerBackdrop)
        headerBackdrop = UIView()
        headerBackdrop.backgroundColor = UIColor.whiteColor()
        view.addSubview(headerBackdrop)

        log.debug("BVC setting up webViewContainer…")
        webViewContainerBackdrop = UIView()
        webViewContainerBackdrop.backgroundColor = UIColor.grayColor()
        webViewContainerBackdrop.alpha = 0
        view.addSubview(webViewContainerBackdrop)

        webViewContainer = UIView()
        webViewContainer.addSubview(webViewContainerToolbar)
        view.addSubview(webViewContainer)

        log.debug("BVC setting up status bar…")
        // Temporary work around for covering the non-clipped web view content
        statusBarOverlay = UIView()
        statusBarOverlay.backgroundColor = BrowserViewControllerUX.BackgroundColor
        view.addSubview(statusBarOverlay)

        log.debug("BVC setting up top touch area…")
        topTouchArea = UIButton()
        topTouchArea.isAccessibilityElement = false
        topTouchArea.addTarget(self, action: #selector(BrowserViewController.SELtappedTopArea), forControlEvents: UIControlEvents.TouchUpInside)
        view.addSubview(topTouchArea)

        // Setup the URL bar, wrapped in a view to get transparency effect
#if BRAVE
        // Brave: need to inject in the middle of this function, override won't work
        urlBar = BraveURLBarView()
        urlBar.translatesAutoresizingMaskIntoConstraints = false
        urlBar.delegate = self
        urlBar.browserToolbarDelegate = self
        header = BlurWrapper(view: urlBar)
        view.addSubview(header)
 #endif

        // UIAccessibilityCustomAction subclass holding an AccessibleAction instance does not work, thus unable to generate AccessibleActions and UIAccessibilityCustomActions "on-demand" and need to make them "persistent" e.g. by being stored in BVC
        pasteGoAction = AccessibleAction(name: NSLocalizedString("Paste & Go", comment: "Paste the URL into the location bar and visit"), handler: { () -> Bool in
            if let pasteboardContents = UIPasteboard.generalPasteboard().string {
                self.urlBar(self.urlBar, didSubmitText: pasteboardContents)
                return true
            }
            return false
        })
        pasteAction = AccessibleAction(name: NSLocalizedString("Paste", comment: "Paste the URL into the location bar"), handler: { () -> Bool in
            if let pasteboardContents = UIPasteboard.generalPasteboard().string {
                // Enter overlay mode and fire the text entered callback to make the search controller appear.
                self.urlBar.enterOverlayMode(pasteboardContents, pasted: true)
                self.urlBar(self.urlBar, didEnterText: pasteboardContents)
                return true
            }
            return false
        })
        copyAddressAction = AccessibleAction(name: NSLocalizedString("Copy Address", comment: "Copy the URL from the location bar"), handler: { () -> Bool in
            if let url = self.urlBar.currentURL {
                UIPasteboard.generalPasteboard().URL = url
            }
            return true
        })


        log.debug("BVC setting up search loader…")
        searchLoader = SearchLoader(profile: profile, urlBar: urlBar)

        footer = UIView()
        self.view.addSubview(footer)
        self.view.addSubview(snackBars)
        snackBars.backgroundColor = UIColor.clearColor()
        self.view.addSubview(findInPageContainer)

        scrollController.urlBar = urlBar
        scrollController.header = header
        scrollController.footer = footer
        scrollController.snackBars = snackBars

#if !BRAVE
        log.debug("BVC updating toolbar state…")
        self.updateToolbarStateForTraitCollection(self.traitCollection)

        log.debug("BVC setting up constraints…")
        setupConstraints()
        log.debug("BVC done.")
#endif
    }

    var headerHeightConstraint: Constraint?
    var webViewContainerTopOffset: Constraint?

    func setupConstraints() {
        header.snp_makeConstraints { make in
            scrollController.headerTopConstraint = make.top.equalTo(snp_topLayoutGuideBottom).constraint
            if let headerHeightConstraint = headerHeightConstraint {
                headerHeightConstraint.updateOffset(BraveURLBarView.CurrentHeight)
            } else {
                headerHeightConstraint = make.height.equalTo(BraveURLBarView.CurrentHeight).constraint
            }

            if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
                // iPad layout is customized in BraveTopViewController for showing panels
                make.left.right.equalTo(header.superview!)
            }
        }

        headerBackdrop.snp_makeConstraints { make in
            make.edges.equalTo(self.header)
        }

        webViewContainerBackdrop.snp_makeConstraints { make in
            make.edges.equalTo(webViewContainer)
        }

        webViewContainerToolbar.snp_makeConstraints { make in
            make.left.right.top.equalTo(webViewContainer)
            make.height.equalTo(0)
        }
    }

    override func viewDidLayoutSubviews() {
        log.debug("BVC viewDidLayoutSubviews…")
        super.viewDidLayoutSubviews()
      #if !BRAVE
        statusBarOverlay.snp_remakeConstraints { make in
            make.top.left.right.equalTo(self.view)
            make.height.equalTo(self.topLayoutGuide.length)
        }
      #endif
        log.debug("BVC done.")
    }

    func loadQueuedTabs() {
        log.debug("Loading queued tabs in the background.")

        // Chain off of a trivial deferred in order to run on the background queue.
        succeed().upon() { res in
            self.dequeueQueuedTabs()
        }
    }

    private func dequeueQueuedTabs() {
        assert(!NSThread.currentThread().isMainThread, "This must be called in the background.")
        self.profile.queue.getQueuedTabs() >>== { cursor in

            // This assumes that the DB returns rows in some kind of sane order.
            // It does in practice, so WFM.
            log.debug("Queue. Count: \(cursor.count).")
            if cursor.count <= 0 {
                return
            }

            let urls = cursor.flatMap { $0?.url.asURL }
            if !urls.isEmpty {
                dispatch_async(dispatch_get_main_queue()) {
                    self.tabManager.addTabsForURLs(urls, zombie: false)
                }
            }

            // Clear *after* making an attempt to open. We're making a bet that
            // it's better to run the risk of perhaps opening twice on a crash,
            // rather than losing data.
            self.profile.queue.clearQueuedTabs()
        }
    }

    override func viewWillAppear(animated: Bool) {
        log.debug("BVC viewWillAppear.")
        super.viewWillAppear(animated)
        log.debug("BVC super.viewWillAppear done.")
#if !DISABLE_INTRO_SCREEN
        // On iPhone, if we are about to show the On-Boarding, blank out the browser so that it does
        // not flash before we present. This change of alpha also participates in the animation when
        // the intro view is dismissed.
        if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
            self.view.alpha = (profile.prefs.intForKey(IntroViewControllerSeenProfileKey) != nil) ? 1.0 : 0.0
        }
#endif
#if !BRAVE
        if activeCrashReporter?.previouslyCrashed ?? false {
            log.debug("Previously crashed.")

            // Reset previous crash state
            activeCrashReporter?.resetPreviousCrashState()

            let optedIntoCrashReporting = profile.prefs.boolForKey("crashreports.send.always")
            if optedIntoCrashReporting == nil {
                // Offer a chance to allow the user to opt into crash reporting
                showCrashOptInAlert()
            } else {
                showRestoreTabsAlert()
            }
        } else {
           tabManager.restoreTabs()
        }

        updateTabCountUsingTabManager(tabManager, animated: false)
#endif
    }

    private func showCrashOptInAlert() {
        let alert = UIAlertController.crashOptInAlert(
            sendReportCallback: { _ in
                // Turn on uploading but don't save opt-in flag to profile because this is a one time send.
                //configureActiveCrashReporter(true)
                self.showRestoreTabsAlert()
            },
            alwaysSendCallback: { _ in
                self.profile.prefs.setBool(true, forKey: "crashreports.send.always")
                //configureActiveCrashReporter(true)
                self.showRestoreTabsAlert()
            },
            dontSendCallback: { _ in
                // no-op: Do nothing if we don't want to send it
                self.showRestoreTabsAlert()
            }
        )
        self.presentViewController(alert, animated: true, completion: nil)
    }

    private func showRestoreTabsAlert() {
        guard shouldRestoreTabs() else {
            self.tabManager.addTabAndSelect()
            return
        }

        let alert = UIAlertController.restoreTabsAlert(
            okayCallback: { _ in
                self.tabManager.restoreTabs()
                self.updateTabCountUsingTabManager(self.tabManager, animated: false)
            },
            noCallback: { _ in
                self.tabManager.addTabAndSelect()
                self.updateTabCountUsingTabManager(self.tabManager, animated: false)
            }
        )

        self.presentViewController(alert, animated: true, completion: nil)
    }

    private func shouldRestoreTabs() -> Bool {
        guard let tabsToRestore = TabManager.tabsToRestore() else { return false }
        let onlyNoHistoryTabs = !tabsToRestore.every { $0.sessionData?.urls.count > 1 || !AboutUtils.isAboutHomeURL($0.sessionData?.urls.first) }
        return !onlyNoHistoryTabs && !DebugSettingsBundleOptions.skipSessionRestore
    }

    override func viewDidAppear(animated: Bool) {
        log.debug("BVC viewDidAppear.")

#if !DISABLE_INTRO_SCREEN
        presentIntroViewController()
#endif

        log.debug("BVC intro presented.")
        self.webViewContainerToolbar.hidden = false

        log.debug("BVC calling super.viewDidAppear.")
        super.viewDidAppear(animated)
        log.debug("BVC done.")

        if shouldShowWhatsNewTab() {
            if let whatsNewURL = SupportUtils.URLForTopic("new-ios") {
                self.openURLInNewTab(whatsNewURL)
                profile.prefs.setString(AppInfo.appVersion, forKey: LatestAppVersionProfileKey)
            }
        }

        showQueuedAlertIfAvailable()
    }

    private func shouldShowWhatsNewTab() -> Bool {
        guard let latestMajorAppVersion = profile.prefs.stringForKey(LatestAppVersionProfileKey)?.componentsSeparatedByString(".").first else {
            return DeviceInfo.hasConnectivity()
        }

        return latestMajorAppVersion != AppInfo.majorAppVersion && DeviceInfo.hasConnectivity()
    }

    private func showQueuedAlertIfAvailable() {
        if var queuedAlertInfo = tabManager.selectedTab?.dequeueJavascriptAlertPrompt() {
            let alertController = queuedAlertInfo.alertController()
            alertController.delegate = self
            presentViewController(alertController, animated: true, completion: nil)
        }
    }

    func resetBrowserChrome() {
        // animate and reset transform for browser chrome
        urlBar.updateAlphaForSubviews(1)

        [header,
            footer,
            readerModeBar,
            footerBackdrop,
            headerBackdrop].forEach { view in
                view?.transform = CGAffineTransformIdentity
        }
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()

        topTouchArea.snp_remakeConstraints { make in
            make.top.left.right.equalTo(self.view)
            make.height.equalTo(BrowserViewControllerUX.ShowHeaderTapAreaHeight)
        }

        readerModeBar?.snp_remakeConstraints { make in
            make.top.equalTo(self.header.snp_bottom).constraint
            make.height.equalTo(UIConstants.ToolbarHeight)
            make.leading.trailing.equalTo(self.view)
        }

#if !BRAVE
        webViewContainer.snp_remakeConstraints { make in
            make.left.right.equalTo(self.view)

            if let readerModeBarBottom = readerModeBar?.snp_bottom {
                make.top.equalTo(readerModeBarBottom)
            } else {
                make.top.equalTo(self.header.snp_bottom)
            }

            let findInPageHeight = (findInPageBar == nil) ? 0 : UIConstants.ToolbarHeight
            if let toolbar = self.toolbar {
                make.bottom.equalTo(toolbar.snp_top).offset(-findInPageHeight)
            } else {
                make.bottom.equalTo(self.view).offset(-findInPageHeight)
            }
        }

        // Setup the bottom toolbar
        toolbar?.snp_remakeConstraints { make in
            make.edges.equalTo(self.footerBackground!)
            make.height.equalTo(UIConstants.ToolbarHeight)
        }
#endif

        footer.snp_remakeConstraints { make in
            scrollController.footerBottomConstraint = make.bottom.equalTo(self.view.snp_bottom).constraint
            make.top.equalTo(self.snackBars.snp_top)
            make.leading.trailing.equalTo(self.view)
        }

        footerBackdrop.snp_remakeConstraints { make in
            make.edges.equalTo(self.footer)
        }

        updateSnackBarConstraints()
        footerBackground?.snp_remakeConstraints { make in
            make.bottom.left.right.equalTo(self.footer)
            make.height.equalTo(UIConstants.ToolbarHeight)
        }
        urlBar.setNeedsUpdateConstraints()

        // Remake constraints even if we're already showing the home controller.
        // The home controller may change sizes if we tap the URL bar while on about:home.
        homePanelController?.view.snp_remakeConstraints { make in
            make.top.equalTo(self.header.snp_bottom)
            make.left.right.equalTo(self.view)
            if self.homePanelIsInline {
                make.bottom.equalTo(self.toolbar?.snp_top ?? self.view.snp_bottom)
            } else {
                make.bottom.equalTo(self.view.snp_bottom)
            }
        }

        findInPageContainer.snp_remakeConstraints { make in
            make.left.right.equalTo(self.view)

            if let keyboardHeight = keyboardState?.intersectionHeightForView(self.view) where keyboardHeight > 0 {
                make.bottom.equalTo(self.view).offset(-keyboardHeight)
            } else if let toolbar = self.toolbar {
                make.bottom.equalTo(toolbar.snp_top)
            } else {
                make.bottom.equalTo(self.view)
            }
        }
    }

    func showHomePanelController(inline inline: Bool) {
        log.debug("BVC showHomePanelController.")
        homePanelIsInline = inline

        #if BRAVE
            // we always want to show the bottom toolbar, if this is false, the bottom toolbar is hidden
            homePanelIsInline = true
        #endif

        if homePanelController == nil {
            homePanelController = HomePanelViewController()
            homePanelController!.profile = profile
            homePanelController!.delegate = self
            homePanelController!.url = tabManager.selectedTab?.displayURL
            homePanelController!.view.alpha = 0

            addChildViewController(homePanelController!)
            view.addSubview(homePanelController!.view)
            homePanelController!.didMoveToParentViewController(self)
        }

        let panelNumber = tabManager.selectedTab?.url?.fragment

        // splitting this out to see if we can get better crash reports when this has a problem
        var newSelectedButtonIndex = 0
        if let numberArray = panelNumber?.componentsSeparatedByString("=") {
            if let last = numberArray.last, lastInt = Int(last) {
                newSelectedButtonIndex = lastInt
            }
        }
        homePanelController?.selectedButtonIndex = newSelectedButtonIndex

        // We have to run this animation, even if the view is already showing because there may be a hide animation running
        // and we want to be sure to override its results.
        UIView.animateWithDuration(0.2, animations: { () -> Void in
            self.homePanelController!.view.alpha = 1
        }, completion: { finished in
            if finished {
                self.webViewContainer.accessibilityElementsHidden = true
                UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
            }
        })
        view.setNeedsUpdateConstraints()
        log.debug("BVC done with showHomePanelController.")
    }

    func hideHomePanelController() {
        if let controller = homePanelController {
            UIView.animateWithDuration(0.2, delay: 0, options: .BeginFromCurrentState, animations: { () -> Void in
                controller.view.alpha = 0
            }, completion: { finished in
                if finished {
                    controller.willMoveToParentViewController(nil)
                    controller.view.removeFromSuperview()
                    controller.removeFromParentViewController()
                    self.homePanelController = nil
                    self.webViewContainer.accessibilityElementsHidden = false
                    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)

                    // Refresh the reading view toolbar since the article record may have changed
                    if let readerMode = self.tabManager.selectedTab?.getHelper(ReaderMode.self) where readerMode.state == .Active {
                        self.showReaderModeBar(animated: false)
                    }
                }
            })
        }
    }

    func updateInContentHomePanel(url: NSURL?) {
        if !urlBar.inOverlayMode {
            if AboutUtils.isAboutHomeURL(url){
                urlBar.updateBookmarkStatus(false)
                showHomePanelController(inline: (tabManager.selectedTab?.canGoForward ?? false || tabManager.selectedTab?.canGoBack ?? false))
            } else {
                hideHomePanelController()
            }
        }
    }

    
    func finishEditingAndSubmit(url: NSURL, visitType: VisitType) {
        guard let tab = tabManager.selectedTab else {
            return
        }

        urlBar.currentURL = url
        urlBar.leaveOverlayMode()

#if !BRAVE // TODO hookup when adding desktop AU
        if let webView = tab.webView {
            resetSpoofedUserAgentIfRequired(webView, newURL: url)
        }
#endif
        if let nav = tab.loadRequest(NSURLRequest(URL: url)) {
            self.recordNavigationInTab(tab, navigation: nav, visitType: visitType)
        }
    }

    func addBookmark(url: String, title: String?) {
        let shareItem = ShareItem(url: url, title: title, favicon: nil)
        profile.bookmarks.shareItem(shareItem)
        if #available(iOS 9, *) {
            var userData = [QuickActions.TabURLKey: shareItem.url]
            if let title = shareItem.title {
                userData[QuickActions.TabTitleKey] = title
            }
//            QuickActions.sharedInstance.addDynamicApplicationShortcutItemOfType(.OpenLastBookmark,
//                withUserData: userData,
//                toApplication: UIApplication.sharedApplication())
        }

        // Dispatch to the main thread to update the UI
        dispatch_async(dispatch_get_main_queue()) { _ in
            self.animateBookmarkStar()
            self.urlBar.updateBookmarkStatus(true)
        }
    }

    private func animateBookmarkStar() {
        let offset: CGFloat
        let button: UIButton!

        if let toolbar: BrowserToolbar = self.toolbar {
            offset = BrowserViewControllerUX.BookmarkStarAnimationOffset * -1
            button = toolbar.bookmarkButton
        } else {
            offset = BrowserViewControllerUX.BookmarkStarAnimationOffset
            button = self.urlBar.bookmarkButton
        }

        let offToolbar = CGAffineTransformMakeTranslation(0, offset)

        UIView.animateWithDuration(BrowserViewControllerUX.BookmarkStarAnimationDuration, delay: 0.0, usingSpringWithDamping: 0.6, initialSpringVelocity: 2.0, options: [], animations: { () -> Void in
            button.transform = offToolbar
            let rotation = CABasicAnimation(keyPath: "transform.rotation")
            rotation.toValue = CGFloat(M_PI * 2.0)
            rotation.cumulative = true
            rotation.duration = BrowserViewControllerUX.BookmarkStarAnimationDuration + 0.075
            rotation.repeatCount = 1.0
            rotation.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.70 ,0.18 ,1.00)
            button.imageView?.layer.addAnimation(rotation, forKey: "rotateStar")
        }, completion: { finished in
            UIView.animateWithDuration(BrowserViewControllerUX.BookmarkStarAnimationDuration, delay: 0.15, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: { () -> Void in
                button.transform = CGAffineTransformIdentity
            }, completion: nil)
        })
    }

    func removeBookmark(url: String) {
        profile.bookmarks.modelFactory >>== {
            $0.removeByURL(url).uponQueue(dispatch_get_main_queue()) { res in
                if res.isSuccess {
                    self.urlBar.updateBookmarkStatus(false)
                }
            }
        }
    }

    func SELBookmarkStatusDidChange(notification: NSNotification) {
        if let bookmark = notification.object as? BookmarkItem {
            if bookmark.url == urlBar.currentURL?.absoluteString {
                if let userInfo = notification.userInfo as? Dictionary<String, Bool>{
                    if let added = userInfo["added"]{
                        self.urlBar.updateBookmarkStatus(added)
                    }
                }
            }
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        if urlBar.inOverlayMode {
            urlBar.SELdidClickCancel()
            return true
        } else if let selectedTab = tabManager.selectedTab where selectedTab.canGoBack {
            selectedTab.goBack()
            return true
        }
        return false
    }

//    private func runScriptsOnWebView(webView: WKWebView) {
//        webView.evaluateJavaScript("__firefox__.favicons.getFavicons()", completionHandler:nil)
//    }

    func updateUIForReaderHomeStateForTab(tab: Browser) {
#if BRAVE
        updateURLBarDisplayURL(tab)
        updateInContentHomePanel(tab.url)
        return // TODO Reader Mode hookup. Beware showToolbars is a performance killer.
#endif
//        scrollController.showToolbars(animated: false)
//        if let url = tab.url {
//            if ReaderModeUtils.isReaderModeURL(url) {
//                showReaderModeBar(animated: false)
//                NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BrowserViewController.SELDynamicFontChanged(_:)), name: NotificationDynamicFontChanged, object: nil)
//            } else {
//                hideReaderModeBar(animated: false)
//                NSNotificationCenter.defaultCenter().removeObserver(self, name: NotificationDynamicFontChanged, object: nil)
//            }
//
//            updateInContentHomePanel(url)
//        }
    }

    private func isWhitelistedUrl(url: NSURL) -> Bool {
        for entry in WhiteListedUrls {
            if let _ = url.absoluteString.rangeOfString(entry, options: .RegularExpressionSearch) {
                return UIApplication.sharedApplication().canOpenURL(url)
            }
        }
        return false
    }

    /// Updates the URL bar text and button states.
    /// Call this whenever the page URL changes.
    func updateURLBarDisplayURL(tab: Browser) {
        urlBar.currentURL = tab.displayURL

        let isPage = tab.displayURL?.isWebPage() ?? false
        navigationToolbar.updatePageStatus(isWebPage: isPage)

        guard let url = tab.displayURL?.absoluteString else {
            return
        }

        succeed().upon { _ in
            self.profile.bookmarks.modelFactory >>== {
                $0.isBookmarked(url).uponQueue(dispatch_get_main_queue()) { result in
                    guard let bookmarked = result.successValue else {
                        log.error("Error getting bookmark status: \(result.failureValue).")
                        return
                    }
                    postAsyncToMain(0) {
                        self.urlBar.updateBookmarkStatus(bookmarked)
                    }
                }
            }
        }
    }
    // Mark: Opening New Tabs

    @available(iOS 9, *)
    func switchToPrivacyMode(){
        let isPrivate = true // this func should be expaneded to handle exiting, which requires a deferred return val
        if isPrivate {
            PrivateBrowsing.singleton.enter()
        }
        // exiting is async and non-trivial for Brave, not currently handled here
        
        applyTheme(isPrivate ? Theme.PrivateMode : Theme.NormalMode)

        let tabTrayController = self.tabTrayController ?? TabTrayController(tabManager: tabManager, profile: profile, tabTrayDelegate: self)
        if tabTrayController.privateMode != isPrivate {
            tabTrayController.changePrivacyMode(isPrivate)
        }
        self.tabTrayController = tabTrayController
    }

    func switchToTabForURLOrOpen(url: NSURL, isPrivate: Bool = false) {
        let tab = tabManager.getTabForURL(url)
        popToBrowser(tab)
        if let tab = tab {
            tabManager.selectTab(tab)
        } else {
            openURLInNewTab(url, isPrivate: isPrivate)
        }
    }

    func openURLInNewTab(url: NSURL?, isPrivate ignored:Bool = false) {
        if let selectedTab = tabManager.selectedTab {
            screenshotHelper.takeScreenshot(selectedTab)
        }

        let request: NSURLRequest?
        if let url = url {
            request = NSURLRequest(URL: url)
        } else {
            request = nil
        }

        let isPrivate = PrivateBrowsing.singleton.isOn

        if #available(iOS 9, *) {
            if isPrivate {
                switchToPrivacyMode()
            }
            tabManager.addTabAndSelect(request, isPrivate: isPrivate)
        } else {
            tabManager.addTabAndSelect(request)
        }
    }

    func openBlankNewTabAndFocus(isPrivate isPrivate: Bool = false) {
        popToBrowser()
        tabManager.selectTab(nil)
        openURLInNewTab(nil, isPrivate: isPrivate)
    }

    private func popToBrowser(forTab: Browser? = nil) {
        guard let currentViewController = navigationController?.topViewController else {
                return
        }
        if let presentedViewController = currentViewController.presentedViewController {
            presentedViewController.dismissViewControllerAnimated(false, completion: nil)
        }
        // if a tab already exists and the top VC is not the BVC then pop the top VC, otherwise don't.
        if currentViewController != self,
            let _ = forTab {
            self.navigationController?.popViewControllerAnimated(true)
        }
    }

    // Mark: User Agent Spoofing
#if !BRAVE // TODO hookup when adding desktop AU
    private func resetSpoofedUserAgentIfRequired(webView: WKWebView, newURL: NSURL) {
        guard #available(iOS 9.0, *) else {
            return
        }
        // Reset the UA when a different domain is being loaded
        if webView.URL?.host != newURL.host {
            webView.customUserAgent = nil
        }
    }

    private func restoreSpoofedUserAgentIfRequired(webView: WKWebView, newRequest: NSURLRequest) {
        guard #available(iOS 9.0, *) else {
            return
        }

        // Restore any non-default UA from the request's header
        let ua = newRequest.valueForHTTPHeaderField("User-Agent")
        webView.customUserAgent = ua != UserAgent.defaultUserAgent() ? ua : nil
    }
#endif

    func presentActivityViewController(url: NSURL, tab: Browser? = nil, sourceView: UIView?, sourceRect: CGRect, arrowDirection: UIPopoverArrowDirection) {
        var activities = [UIActivity]()

        let findInPageActivity = FindInPageActivity() { [unowned self] in
            self.updateFindInPageVisibility(visible: true)
        }
        activities.append(findInPageActivity)

        #if !BRAVE
        if #available(iOS 9.0, *) {
            if let tab = tab where (tab.getHelper(name: ReaderMode.name()) as? ReaderMode)?.state != .Active {
                let requestDesktopSiteActivity = RequestDesktopSiteActivity(requestMobileSite: tab.desktopSite) { [unowned tab] in
                    tab.toggleDesktopSite()
                }
                activities.append(requestDesktopSiteActivity)
            }
        }
        #endif

        let helper = ShareExtensionHelper(url: url, tab: tab, activities: activities)

        let controller = helper.createActivityViewController({ [unowned self, weak tab = tab] completed in
            // After dismissing, check to see if there were any prompts we queued up
            self.showQueuedAlertIfAvailable()

            self.displayedPopoverController = nil
            self.updateDisplayedPopoverProperties = nil

            if completed {
                // We don't know what share action the user has chosen so we simply always
                // update the toolbar and reader mode bar to reflect the latest status.
                if let tab = tab {
                    self.updateURLBarDisplayURL(tab)
                }
                self.updateReaderModeBar()
            }
        })

        let setupPopover = { [unowned self, weak controller = controller, weak sourceView = sourceView] in
            if let popoverPresentationController = controller?.popoverPresentationController {
                popoverPresentationController.sourceView = sourceView
                popoverPresentationController.sourceRect = sourceRect
                popoverPresentationController.permittedArrowDirections = arrowDirection
                popoverPresentationController.delegate = self
            }
        }

        setupPopover()

        if controller.popoverPresentationController != nil {
            displayedPopoverController = controller
            updateDisplayedPopoverProperties = setupPopover
        }

        self.presentViewController(controller, animated: true, completion: nil)
    }

    func updateFindInPageVisibility(visible visible: Bool) {
        if visible {
            if findInPageBar == nil {
                let findInPageBar = FindInPageBar()
                self.findInPageBar = findInPageBar
                findInPageBar.delegate = self
                findInPageContainer.addSubview(findInPageBar)

                findInPageBar.snp_makeConstraints { make in
                    make.edges.equalTo(findInPageContainer)
                    make.height.equalTo(UIConstants.ToolbarHeight)
                }

                updateViewConstraints()

                // We make the find-in-page bar the first responder below, causing the keyboard delegates
                // to fire. This, in turn, will animate the Find in Page container since we use the same
                // delegate to slide the bar up and down with the keyboard. We don't want to animate the
                // constraints added above, however, so force a layout now to prevent these constraints
                // from being lumped in with the keyboard animation.
                findInPageBar.layoutIfNeeded()
            }

            self.findInPageBar?.becomeFirstResponder()
        } else if let findInPageBar = self.findInPageBar {
            findInPageBar.endEditing(true)
            guard let webView = tabManager.selectedTab?.webView else { return }
            webView.evaluateJavaScript("__firefox__.findDone()", completionHandler: nil)
            findInPageBar.removeFromSuperview()
            self.findInPageBar = nil
            updateViewConstraints()
        }
    }

    override func canBecomeFirstResponder() -> Bool {
        return true
    }

//    override func becomeFirstResponder() -> Bool {
//        // Make the web view the first responder so that it can show the selection menu.
//        return tabManager.selectedTab?.webView?.becomeFirstResponder() ?? false
//    }
}

/**
 * History visit management.
 * TODO: this should be expanded to track various visit types; see Bug 1166084.
 */
extension BrowserViewController {
    func ignoreNavigationInTab(tab: Browser, navigation: WKNavigation) {
        self.ignoredNavigation.insert(navigation)
    }

    func recordNavigationInTab(tab: Browser, navigation: WKNavigation, visitType: VisitType) {
        self.typedNavigation[navigation] = visitType
    }

    /**
     * Untrack and do the right thing.
     */
    func getVisitTypeForTab(tab: Browser, navigation: WKNavigation?) -> VisitType? {
        guard let navigation = navigation else {
            // See https://github.com/WebKit/webkit/blob/master/Source/WebKit2/UIProcess/Cocoa/NavigationState.mm#L390
            return VisitType.Link
        }

        if let _ = self.ignoredNavigation.remove(navigation) {
            return nil
        }

        return self.typedNavigation.removeValueForKey(navigation) ?? VisitType.Link
    }
}

extension BrowserViewController: WindowCloseHelperDelegate {
    func windowCloseHelper(helper: WindowCloseHelper, didRequestToCloseBrowser browser: Browser) {
        tabManager.removeTab(browser, createTabIfNoneLeft: true)
    }
}


extension BrowserViewController: HomePanelViewControllerDelegate {
    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectURL url: NSURL, visitType: VisitType) {
        finishEditingAndSubmit(url, visitType: visitType)
    }

    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectPanel panel: Int) {
        if AboutUtils.isAboutHomeURL(tabManager.selectedTab?.url) {
            tabManager.selectedTab?.webView?.evaluateJavaScript("history.replaceState({}, '', '#panel=\(panel)')", completionHandler: nil)
        }
    }

    func homePanelViewControllerDidRequestToCreateAccount(homePanelViewController: HomePanelViewController) {
        #if !BRAVE
        presentSignInViewController() // TODO UX Right now the flow for sign in and create account is the same
        #endif
    }

    func homePanelViewControllerDidRequestToSignIn(homePanelViewController: HomePanelViewController) {
        #if !BRAVE
        presentSignInViewController() // TODO UX Right now the flow for sign in and create account is the same
        #endif
    }
}

extension BrowserViewController: SearchViewControllerDelegate {
    func searchViewController(searchViewController: SearchViewController, didSelectURL url: NSURL) {
        finishEditingAndSubmit(url, visitType: VisitType.Typed)
    }

    func presentSearchSettingsController() {
        let settingsNavigationController = SearchSettingsTableViewController()
        settingsNavigationController.model = self.profile.searchEngines

        let navController = UINavigationController(rootViewController: settingsNavigationController)

        self.presentViewController(navController, animated: true, completion: nil)
    }
}

extension BrowserViewController: ReaderModeDelegate {
    func readerMode(readerMode: ReaderMode, didChangeReaderModeState state: ReaderModeState, forBrowser browser: Browser) {
        // If this reader mode availability state change is for the tab that we currently show, then update
        // the button. Otherwise do nothing and the button will be updated when the tab is made active.
        if tabManager.selectedTab === browser {
            urlBar.updateReaderModeState(state)
        }
    }

    func readerMode(readerMode: ReaderMode, didDisplayReaderizedContentForBrowser browser: Browser) {
        self.showReaderModeBar(animated: true)
        browser.showContent(true)
    }

    // Returning None here makes sure that the Popover is actually presented as a Popover and
    // not as a full-screen modal, which is the default on compact device classes.
    func adaptivePresentationStyleForPresentationController(controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return UIModalPresentationStyle.None
    }
}

// MARK: - UIPopoverPresentationControllerDelegate

extension BrowserViewController: UIPopoverPresentationControllerDelegate {
    func popoverPresentationControllerDidDismissPopover(popoverPresentationController: UIPopoverPresentationController) {
        displayedPopoverController = nil
        updateDisplayedPopoverProperties = nil
    }
}

extension BrowserViewController: IntroViewControllerDelegate {
    func presentIntroViewController(force: Bool = false) -> Bool{
        if force || profile.prefs.intForKey(IntroViewControllerSeenProfileKey) == nil {
            let introViewController = IntroViewController()
            introViewController.delegate = self
            // On iPad we present it modally in a controller
            if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
                introViewController.preferredContentSize = CGSize(width: IntroViewControllerUX.Width, height: IntroViewControllerUX.Height)
                introViewController.modalPresentationStyle = UIModalPresentationStyle.FormSheet
            }
            presentViewController(introViewController, animated: true) {
                self.profile.prefs.setInt(1, forKey: IntroViewControllerSeenProfileKey)
            }

            return true
        }

        return false
    }

    func introViewControllerDidFinish(introViewController: IntroViewController) {
        introViewController.dismissViewControllerAnimated(true) { finished in
            if self.navigationController?.viewControllers.count > 1 {
                self.navigationController?.popToRootViewControllerAnimated(true)
            }
        }
    }

    #if !BRAVE
    func presentSignInViewController() {
        // Show the settings page if we have already signed in. If we haven't then show the signin page
        let vcToPresent: UIViewController
        if profile.hasAccount() {
            let settingsTableViewController = AppSettingsTableViewController()
            settingsTableViewController.profile = profile
            settingsTableViewController.tabManager = tabManager
            vcToPresent = settingsTableViewController
        } else {
            let signInVC = FxAContentViewController()
            signInVC.delegate = self
            signInVC.url = profile.accountConfiguration.signInURL
            signInVC.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: UIBarButtonSystemItem.Cancel, target: self, action: #selector(BrowserViewController.dismissSignInViewController))
            vcToPresent = signInVC
        }

        let settingsNavigationController = SettingsNavigationController(rootViewController: vcToPresent)
		settingsNavigationController.modalPresentationStyle = .FormSheet
        self.presentViewController(settingsNavigationController, animated: true, completion: nil)
    }

    func dismissSignInViewController() {
        self.dismissViewControllerAnimated(true, completion: nil)
    }

    func introViewControllerDidRequestToLogin(introViewController: IntroViewController) {
        introViewController.dismissViewControllerAnimated(true, completion: { () -> Void in
            self.presentSignInViewController()
        })
    }
    #endif
}

extension BrowserViewController: FxAContentViewControllerDelegate {
    func contentViewControllerDidSignIn(viewController: FxAContentViewController, data: JSON) -> Void {
        if data["keyFetchToken"].asString == nil || data["unwrapBKey"].asString == nil {
            // The /settings endpoint sends a partial "login"; ignore it entirely.
            log.debug("Ignoring didSignIn with keyFetchToken or unwrapBKey missing.")
            return
        }

        // TODO: Error handling.
        let account = FirefoxAccount.fromConfigurationAndJSON(profile.accountConfiguration, data: data)!
        profile.setAccount(account)
        if let account = self.profile.getAccount() {
            account.advance()
        }
        self.dismissViewControllerAnimated(true, completion: nil)
    }

    func contentViewControllerDidCancel(viewController: FxAContentViewController) {
        log.info("Did cancel out of FxA signin")
        self.dismissViewControllerAnimated(true, completion: nil)
    }
}


extension BrowserViewController: KeyboardHelperDelegate {
    func keyboardHelper(keyboardHelper: KeyboardHelper, keyboardWillShowWithState state: KeyboardState) {
        keyboardState = state
        updateViewConstraints()

        UIView.animateWithDuration(state.animationDuration) {
            UIView.setAnimationCurve(state.animationCurve)
            self.findInPageContainer.layoutIfNeeded()
            self.snackBars.layoutIfNeeded()
        }
    }

    func keyboardHelper(keyboardHelper: KeyboardHelper, keyboardDidShowWithState state: KeyboardState) {
    }

    func keyboardHelper(keyboardHelper: KeyboardHelper, keyboardWillHideWithState state: KeyboardState) {
        keyboardState = nil
        updateViewConstraints()

        UIView.animateWithDuration(state.animationDuration) {
            UIView.setAnimationCurve(state.animationCurve)
            self.findInPageContainer.layoutIfNeeded()
            self.snackBars.layoutIfNeeded()
        }
    }
}

extension BrowserViewController: SessionRestoreHelperDelegate {
    func sessionRestoreHelper(helper: SessionRestoreHelper, didRestoreSessionForBrowser browser: Browser) {
        browser.restoring = false

        if let tab = tabManager.selectedTab where tab.webView === browser.webView {
            updateUIForReaderHomeStateForTab(tab)
        }
    }
}

extension BrowserViewController: TabTrayDelegate {
    // This function animates and resets the browser chrome transforms when
    // the tab tray dismisses.
    func tabTrayDidDismiss(tabTray: TabTrayController) {
        resetBrowserChrome()
    }

    func tabTrayDidAddBookmark(tab: Browser) {
        guard let url = tab.url?.absoluteString where url.characters.count > 0 else { return }
        self.addBookmark(url, title: tab.title)
    }


    func tabTrayDidAddToReadingList(tab: Browser) -> ReadingListClientRecord? {
        guard let url = tab.url?.absoluteString where url.characters.count > 0 else { return nil }
        return profile.readingList?.createRecordWithURL(url, title: tab.title ?? url, addedBy: UIDevice.currentDevice().name).successValue
    }

    func tabTrayRequestsPresentationOf(viewController viewController: UIViewController) {
        self.presentViewController(viewController, animated: false, completion: nil)
    }
}

// MARK: Browser Chrome Theming
extension BrowserViewController: Themeable {

    func applyTheme(themeName: String) {
        urlBar.applyTheme(themeName)
        toolbar?.applyTheme(themeName)
        readerModeBar?.applyTheme(themeName)

        switch(themeName) {
        case Theme.NormalMode:
            header.blurStyle = .ExtraLight
            footerBackground?.blurStyle = .ExtraLight
        case Theme.PrivateMode:
            header.blurStyle = .Dark
            footerBackground?.blurStyle = .Dark
        default:
            log.debug("Unknown Theme \(themeName)")
        }
    }
}

// A small convienent class for wrapping a view with a blur background that can be modified
class BlurWrapper: UIView {
    var blurStyle: UIBlurEffectStyle = .ExtraLight {
        didSet {
            let newEffect = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
            effectView.removeFromSuperview()
            effectView = newEffect
            insertSubview(effectView, belowSubview: wrappedView)
            effectView.snp_remakeConstraints { make in
                make.edges.equalTo(self)
            }
        }
    }

    var effectView: UIVisualEffectView
    private var wrappedView: UIView

    init(view: UIView) {
        wrappedView = view
        effectView = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
        super.init(frame: CGRectZero)

        addSubview(effectView)
        addSubview(wrappedView)

        effectView.snp_makeConstraints { make in
            make.edges.equalTo(self)
        }

        wrappedView.snp_makeConstraints { make in
            make.edges.equalTo(self)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

protocol Themeable {
    func applyTheme(themeName: String)
}

extension BrowserViewController: JSPromptAlertControllerDelegate {
    func promptAlertControllerDidDismiss(alertController: JSPromptAlertController) {
        showQueuedAlertIfAvailable()
    }
}
