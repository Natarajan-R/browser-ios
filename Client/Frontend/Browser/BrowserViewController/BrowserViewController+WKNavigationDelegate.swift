/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
private let log = Logger.browserLogger

extension BrowserViewController: WKCompatNavigationDelegate {

    func webViewDidStartProvisionalNavigation(webView: UIWebView, url: NSURL?) {
        #if !BRAVE
            if tabManager.selectedTab?.webView !== webView {
                return
            }
        #else
            // remove the open in overlay view if it is present
            removeOpenInView()
        #endif
        updateFindInPageVisibility(visible: false)

        // If we are going to navigate to a new page, hide the reader mode button. Unless we
        // are going to a about:reader page. Then we keep it on screen: it will change status
        // (orange color) as soon as the page has loaded.
        if let url = tabManager.tabForWebView(webView)?.url {
            if !ReaderModeUtils.isReaderModeURL(url) {
                urlBar.updateReaderModeState(ReaderModeState.Unavailable)
                hideReaderModeBar(animated: false)
            }

        }
    }

    // Recognize an Apple Maps URL. This will trigger the native app. But only if a search query is present. Otherwise
    // it could just be a visit to a regular page on maps.apple.com.
    private func isAppleMapsURL(url: NSURL) -> Bool {
        if url.scheme == "http" || url.scheme == "https" {
            if url.host == "maps.apple.com" && url.query != nil {
                return true
            }
        }
        return false
    }

    // Recognize a iTunes Store URL. These all trigger the native apps. Note that appstore.com and phobos.apple.com
    // used to be in this list. I have removed them because they now redirect to itunes.apple.com. If we special case
    // them then iOS will actually first open Safari, which then redirects to the app store. This works but it will
    // leave a 'Back to Safari' button in the status bar, which we do not want.
    private func isStoreURL(url: NSURL) -> Bool {
        if url.scheme == "http" || url.scheme == "https" {
            if url.host == "itunes.apple.com" {
                return true
            }
        }
        return false
    }

    // This is the place where we decide what to do with a new navigation action. There are a number of special schemes
    // and http(s) urls that need to be handled in a different way. All the logic for that is inside this delegate
    // method.
    func webViewDecidePolicyForNavigationAction(webView: UIWebView, url: NSURL?, inout shouldLoad: Bool) {
        guard let url = url else { return }
        // Fixes 1261457 - Rich text editor fails because requests to about:blank are blocked
        if url.scheme == "about" && url.resourceSpecifier == "blank" {
            return
        }

        // First special case are some schemes that are about Calling. We prompt the user to confirm this action. This
        // gives us the exact same behaviour as Safari. The only thing we do not do is nicely format the phone number,
        // instead we present it as it was put in the URL.

        if url.scheme == "tel" || url.scheme == "facetime" || url.scheme == "facetime-audio" {
            if let phoneNumber = url.resourceSpecifier.stringByRemovingPercentEncoding {
                let alert = UIAlertController(title: phoneNumber, message: nil, preferredStyle: UIAlertControllerStyle.Alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment:"Alert Cancel Button"), style: UIAlertActionStyle.Cancel, handler: nil))
                alert.addAction(UIAlertAction(title: NSLocalizedString("Call", comment:"Alert Call Button"), style: UIAlertActionStyle.Default, handler: { (action: UIAlertAction!) in
                    UIApplication.sharedApplication().openURL(url)
                }))
                presentViewController(alert, animated: true, completion: nil)
            }
            shouldLoad = false
            return
        }

        // Second special case are a set of URLs that look like regular http links, but should be handed over to iOS
        // instead of being loaded in the webview. Note that there is no point in calling canOpenURL() here, because
        // iOS will always say yes. TODO Is this the same as isWhitelisted?

        if isAppleMapsURL(url) {
            UIApplication.sharedApplication().openURL(url)
            shouldLoad = false
            return
        }


        if let tab = tabManager.selectedTab where isStoreURL(url) {
            struct StaticTag {
                static let tag = Int(arc4random())
            }
            let hasOneAlready = tab.bars.contains({ $0.tag == StaticTag.tag })
            if hasOneAlready ?? false {
                return
            }

            let siteName = tab.displayURL?.hostWithGenericSubdomainPrefixRemoved() ?? "this site"
            let snackBar = TimerSnackBar(attrText: NSAttributedString(string: NSLocalizedString("  Allow \(siteName) to open iTunes?", comment: "Ask user if site can open iTunes store URL")),
                                         img: nil,
                                         buttons: [
                                            SnackButton(title: "Open", accessibilityIdentifier: "", callback: { bar in
                                                self.tabManager.selectedTab?.removeSnackbar(bar)
                                                UIApplication.sharedApplication().openURL(url)
                                            }),
                                            SnackButton(title: "Not now", accessibilityIdentifier: "", callback: { bar in
                                                self.tabManager.selectedTab?.removeSnackbar(bar)
                                            })
                ])
            snackBar.tag = StaticTag.tag
            tabManager.selectedTab?.addSnackbar(snackBar)
            return
        }


        // This is the normal case, opening a http or https url, which we handle by loading them in this WKWebView. We
        // always allow this.
        if url.scheme == "http" || url.scheme == "https" {
            #if !BRAVE
                if navigationAction.navigationType == .LinkActivated {
                    resetSpoofedUserAgentIfRequired(webView, newURL: url)
                } else if navigationAction.navigationType == .BackForward {
                    restoreSpoofedUserAgentIfRequired(webView, newRequest: navigationAction.request)
                }
            #endif
            return
        }

        // Default to calling openURL(). What this does depends on the iOS version. On iOS 8, it will just work without
        // prompting. On iOS9, depending on the scheme, iOS will prompt: "Firefox" wants to open "Twitter". It will ask
        // every time. There is no way around this prompt. (TODO Confirm this is true by adding them to the Info.plist)

        UIApplication.sharedApplication().openURL(url)
        shouldLoad = false
    }

    func webViewDidFinishNavigation(webView: UIWebView, url: NSURL?) {
        guard let tab = tabManager.tabForWebView(webView) else { return }
        tabManager.expireSnackbars()
        tab.lastExecutedTime = NSDate.now()

        if let url = url where !ErrorPageHelper.isErrorPageURL(url) && !AboutUtils.isAboutHomeURL(url) {

            updateProfileForLocationChange(tab)

            // Fire the readability check. This is here and not in the pageShow event handler in ReaderMode.js anymore
            // because that event wil not always fire due to unreliable page caching. This will either let us know that
            // the currently loaded page can be turned into reading mode or if the page already is in reading mode. We
            // ignore the result because we are being called back asynchronous when the readermode status changes.
            #if !BRAVE
                webView.evaluateJavaScript("_firefox_ReaderMode.checkReadability()", completionHandler: nil)
            #endif
        }

        if tab === tabManager.selectedTab {
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
            // must be followed by LayoutChanged, as ScreenChanged will make VoiceOver
            // cursor land on the correct initial element, but if not followed by LayoutChanged,
            // VoiceOver will sometimes be stuck on the element, not allowing user to move
            // forward/backward. Strange, but LayoutChanged fixes that.
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil)
        }

        #if BRAVE
            screenshotHelper.takeDelayedScreenshot(tab)
        #endif
        addOpenInViewIfNeccessary(tab.url)
    }

    func addOpenInViewIfNeccessary(url: NSURL?) {
        guard let url = url, let openInHelper = OpenInHelperFactory.helperForURL(url) else { return }
        let view = openInHelper.openInView
        webViewContainerToolbar.addSubview(view)
        webViewContainerToolbar.snp_updateConstraints { make in
            make.height.equalTo(OpenInViewUX.ViewHeight)
        }
        view.snp_makeConstraints { make in
            make.edges.equalTo(webViewContainerToolbar)
        }

        self.openInHelper = openInHelper
    }

    func removeOpenInView() {
        guard let _ = self.openInHelper else { return }
        webViewContainerToolbar.subviews.forEach { $0.removeFromSuperview() }

        webViewContainerToolbar.snp_updateConstraints { make in
            make.height.equalTo(0)
        }

        self.openInHelper = nil
    }

    private func updateProfileForLocationChange(tab: Browser) {
        var info = [String : AnyObject]()
        info["url"] = tab.displayURL
        info["title"] = tab.title
        info["visitType"] = 1 // VisitType.Link
        info["isPrivate"] = tab.isPrivate
        if !(tab.title?.isEmpty ?? true) {
            (profile as? BrowserProfile)?.onLocationChange(info)
        }
    }


    func webViewDidFailNavigation(webView: UIWebView, withError error: NSError) {
        // Ignore the "Frame load interrupted" error that is triggered when we cancel a request
        // to open an external application and hand it over to UIApplication.openURL(). The result
        // will be that we switch to the external app, for example the app store, while keeping the
        // original web page in the tab instead of replacing it with an error page.
        if error.domain == "WebKitErrorDomain" && error.code == 102 {
            return
        }

        if error.code == Int(CFNetworkErrors.CFURLErrorCancelled.rawValue) {
            if let tab = tabManager.tabForWebView(webView) where tab === tabManager.selectedTab {
                urlBar.currentURL = tab.displayURL
            }
            return
        }

        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? NSURL {
            ErrorPageHelper().showPage(error, forUrl: url, inWebView: webView)
        }
    }

}