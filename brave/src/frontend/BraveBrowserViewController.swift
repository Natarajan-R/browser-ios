/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import SnapKit

class BraveBrowserViewController : BrowserViewController {
    var historySwiper = HistorySwiper()

    override func applyTheme(themeName: String) {
        super.applyTheme(themeName)

        toolbar?.accessibilityLabel = "toolbar thing"
        headerBackdrop.accessibilityLabel = "headerBackdrop"
        webViewContainerBackdrop.accessibilityLabel = "webViewContainerBackdrop"
        webViewContainer.accessibilityLabel = "webViewContainer"
        statusBarOverlay.accessibilityLabel = "statusBarOverlay"
        urlBar.accessibilityLabel = "BraveUrlBar"

        // TODO sorry, I am in a rush, but this needs to be removed from the view heirarchy properly
        headerBackdrop.backgroundColor = UIColor.clearColor()
        headerBackdrop.alpha = 0
        headerBackdrop.hidden = true

        header.blurStyle = .Dark
        footerBackground?.blurStyle = .Dark

        toolbar?.applyTheme(themeName)
    }

    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)

        struct RunOnceGuard { static var ran = false }
        if !RunOnceGuard.ran && profile.prefs.boolForKey(kPrefKeyPrivateBrowsingAlwaysOn) ?? false {
            postAsyncToMain(0) {
                if #available(iOS 9, *) {
                    getApp().browserViewController.switchToPrivacyMode()
                    getApp().tabManager.addTabAndSelect(isPrivate: true)
                }
            }
        }
        RunOnceGuard.ran = true
    }

    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)

        self.updateToolbarStateForTraitCollection(self.traitCollection)
        setupConstraints()
        if BraveApp.shouldRestoreTabs() {
            tabManager.restoreTabs()
        } else {
            tabManager.addTabAndSelect()
        }

        updateTabCountUsingTabManager(tabManager, animated: false)

        footer.accessibilityLabel = "footer"
        footerBackdrop.accessibilityLabel = "footerBackdrop"

        // With this color, it matches to default semi-transparent state of the toolbar
        // The value is hand-picked to match the effect on the url bar, we don't have a color constant for this elsewhere
        statusBarOverlay.backgroundColor = DeviceInfo.isBlurSupported() ? UIColor(white: 0.255, alpha: 1.0) : UIColor.blackColor()
    }

    func updateBraveShieldButtonState(animated animated: Bool) {
        guard let s = tabManager.selectedTab?.webView?.braveShieldState else { return }
        let up = s.isNotSet() || !s.isAllOff()
        (urlBar as! BraveURLBarView).setBraveButtonState(shieldsUp: up, animated: animated)
    }

    override func selectedTabChanged(selected: Browser) {
        historySwiper.setup(topLevelView: self.view, webViewContainer: self.webViewContainer)
        for swipe in [historySwiper.goBackSwipe, historySwiper.goForwardSwipe] {
            selected.webView?.scrollView.panGestureRecognizer.requireGestureRecognizerToFail(swipe)
            scrollController.panGesture.requireGestureRecognizerToFail(swipe)
        }

        if let webView = selected.webView {
            webViewContainer.insertSubview(webView, atIndex: 0)
            webView.snp_makeConstraints { make in
                make.top.equalTo(webViewContainerToolbar.snp_bottom)
                make.left.right.bottom.equalTo(self.webViewContainer)
            }

            urlBar.updateProgressBar(Float(webView.estimatedProgress), dueToTabChange: true)
            urlBar.updateReloadStatus(webView.loading)
            updateBraveShieldButtonState(animated: false)

            if let bravePanel = (getApp().rootViewController.visibleViewController as? BraveTopViewController)?.rightSidePanel {
                bravePanel.setShieldBlockedStats(webView.shieldStats)
                bravePanel.updateSitenameAndTogglesState()
            }
        }
        postAsyncToMain(0.1) {
            self.becomeFirstResponder()
        }
    }

    override func SELtappedTopArea() {
     //   scrollController.showToolbars(animated: true)
    }

    var heightConstraint: Constraint?
    override func setupConstraints() {
        super.setupConstraints()

        if heightConstraint == nil {
            webViewContainer.snp_makeConstraints { make in
                make.left.right.equalTo(self.view)
                heightConstraint = make.height.equalTo(self.view.snp_height).constraint
                webViewContainerTopOffset = make.top.equalTo(self.statusBarOverlay.snp_bottom).offset(BraveURLBarView.CurrentHeight).constraint
            }
        }

        heightConstraint?.updateOffset(-BraveApp.statusBarHeight())
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()

        // Setup the bottom toolbar
        toolbar?.snp_remakeConstraints { make in
            make.edges.equalTo(self.footerBackground!)
        }

        heightConstraint?.updateOffset(-BraveApp.statusBarHeight())
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let h = BraveApp.isIPhoneLandscape() ? 0 : 20
        statusBarOverlay.snp_remakeConstraints { make in
            make.top.left.right.equalTo(self.view)
            make.height.equalTo(h)
        }
    }
    
    override func updateToolbarStateForTraitCollection(newCollection: UITraitCollection) {
        super.updateToolbarStateForTraitCollection(newCollection)

        heightConstraint?.updateOffset(-BraveApp.statusBarHeight())

        postAsyncToMain(0) {
            self.urlBar.updateTabsBarShowing()
        }
    }

    override func showHomePanelController(inline inline:Bool) {
        super.showHomePanelController(inline: inline)
        postAsyncToMain(0.1) {
            if UIResponder.currentFirstResponder() == nil {
                self.becomeFirstResponder()
            }
        }
    }

    override func hideHomePanelController() {
        super.hideHomePanelController()

        // For bizzaro reasons, this can take a few delayed attempts. The first responder is getting set to nil -I *did* search the codebase for any resigns that could cause this.
        func setSelfAsFirstResponder(attempt: Int) {
            if UIResponder.currentFirstResponder() === self {
                return
            }
            if attempt > 5 {
                print("Failed to set BVC as first responder ;(")
                return
            }
            postAsyncToMain(0.1) {
                self.becomeFirstResponder()
                setSelfAsFirstResponder(attempt + 1)
            }
        }

        postAsyncToMain(0.1) {
           setSelfAsFirstResponder(0)
        }
    }
}

weak var _firstResponder:UIResponder?
extension UIResponder {
    func findFirstResponder() {
        _firstResponder = self
    }

    static func currentFirstResponder() -> UIResponder? {
        if (UIApplication.sharedApplication().sendAction(#selector(findFirstResponder), to: nil, from: nil, forEvent: nil)) {
            return _firstResponder
        } else {
            return nil
        }
    }
}
