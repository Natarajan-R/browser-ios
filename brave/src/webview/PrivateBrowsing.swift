import Shared
import Deferred
import Crashlytics

private let _singleton = PrivateBrowsing()

class PrivateBrowsing {
    class var singleton: PrivateBrowsing {
        return _singleton
    }

    private(set) var isOn = false

    var nonprivateCookies = [NSHTTPCookie: Bool]()

    // On startup we are no longer in private mode, if there is a .public cookies file, it means app was killed in private mode, so restore the cookies file
    func startupCheckIfKilledWhileInPBMode() {
        webkitDirLocker(lock: false)
        cookiesFileDiskOperation(.Restore)
    }

    enum MoveCookies {
        case SavePublicBackup
        case Restore
        case DeletePublicBackup
    }

    // GeolocationSites.plist cannot be blocked any other way than locking the filesystem so that webkit can't write it out
    // TODO: after unlocking, verify that sites from PB are not in the written out GeolocationSites.plist, based on manual testing this
    // doesn't seem to be the case, but more rigourous test cases are needed
    private func webkitDirLocker(lock lock: Bool) {
        let fm = NSFileManager.defaultManager()
        let baseDir = NSSearchPathForDirectoriesInDomains(.LibraryDirectory, .UserDomainMask, true)[0]
        let webkitDir = baseDir + "/WebKit"
        do {
            try fm.setAttributes([NSFilePosixPermissions: (lock ? NSNumber(short:0) : NSNumber(short:0o755))], ofItemAtPath: webkitDir)
        } catch {
            print(error)
        }
    }

    private func cookiesFileDiskOperation(let type: MoveCookies) {
        let fm = NSFileManager.defaultManager()
        let baseDir = NSSearchPathForDirectoriesInDomains(.LibraryDirectory, .UserDomainMask, true)[0]
        let cookiesDir = baseDir + "/Cookies"
        let originSuffix = type == .SavePublicBackup ? "cookies" : ".public"

        do {
            let contents = try fm.contentsOfDirectoryAtPath(cookiesDir)
            for item in contents {
                if item.hasSuffix(originSuffix) {
                    if type == .DeletePublicBackup {
                        try fm.removeItemAtPath(cookiesDir + "/" + item)
                    } else {
                        var toPath = cookiesDir + "/"
                        if type == .Restore {
                            toPath += NSString(string: item).stringByDeletingPathExtension
                        } else {
                            toPath += item + ".public"
                        }
                        if fm.fileExistsAtPath(toPath) {
                            do { try fm.removeItemAtPath(toPath) } catch {}
                        }
                        try fm.moveItemAtPath(cookiesDir + "/" + item, toPath: toPath)
                    }
                }
            }
        } catch {
            print(error)
        }
    }

    func enter() {
        if isOn {
            return
        }

        isOn = true

        getApp().tabManager.enterPrivateBrowsingMode(self)

        cookiesFileDiskOperation(.SavePublicBackup)

        NSURLCache.sharedURLCache().memoryCapacity = 0;
        NSURLCache.sharedURLCache().diskCapacity = 0;

        let storage = NSHTTPCookieStorage.sharedHTTPCookieStorage()
        if let cookies = storage.cookies {
            for cookie in cookies {
                nonprivateCookies[cookie] = true
                storage.deleteCookie(cookie)
            }
        }

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(PrivateBrowsing.cookiesChanged(_:)), name: NSHTTPCookieManagerCookiesChangedNotification, object: nil)

        webkitDirLocker(lock: true)

        NSUserDefaults.standardUserDefaults().setBool(true, forKey: "WebKitPrivateBrowsingEnabled")
    }

    private var exitDeferred = Deferred<()>()
    func exit() -> Deferred<()> {
        let isAlwaysPrivate = getApp().profile?.prefs.boolForKey(kPrefKeyPrivateBrowsingAlwaysOn) ?? false

        exitDeferred = Deferred<()>()
        if isAlwaysPrivate || !isOn {
            exitDeferred.fill(())
            return exitDeferred
        }

        isOn = false
        NSUserDefaults.standardUserDefaults().setBool(false, forKey: "WebKitPrivateBrowsingEnabled")
        NSNotificationCenter.defaultCenter().removeObserver(self)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(allWebViewsKilled), name: kNotificationAllWebViewsDeallocated, object: nil)

        getApp().tabManager.removeAllPrivateTabsAndNotify(false)
        postAsyncToMain(2) {
#if !NO_FABRIC
            Answers.logCustomEventWithName("PrivateBrowsing exit failed", customAttributes: nil)
#endif
            self.allWebViewsKilled()
        }

        return exitDeferred
    }

    @objc func allWebViewsKilled() {
        struct ReentrantGuard {
            static var inFunc = false
        }

        if ReentrantGuard.inFunc {
            return
        }
        ReentrantGuard.inFunc = true

        NSNotificationCenter.defaultCenter().removeObserver(self)
        postAsyncToMain(0.25) { // even after all webviews killed, an added delay is needed before the webview state is fully cleared, this is horrible. Fortunately, I have only seen this behaviour on the simulator.

            self.webkitDirLocker(lock: false)
            BraveApp.setupCacheDefaults()

            let clear: [Clearable] = [CacheClearable(), CookiesClearable()]
            ClearPrivateDataTableViewController.clearPrivateData(clear).uponQueue(dispatch_get_main_queue()) { _ in
                self.cookiesFileDiskOperation(.DeletePublicBackup)
                let storage = NSHTTPCookieStorage.sharedHTTPCookieStorage()
                for cookie in self.nonprivateCookies {
                    storage.setCookie(cookie.0)
                }
                self.nonprivateCookies = [NSHTTPCookie: Bool]()

                getApp().tabManager.exitPrivateBrowsingMode(self)

                self.exitDeferred.fillIfUnfilled(())
                ReentrantGuard.inFunc = false
            }
        }
    }

    @objc func cookiesChanged(info: NSNotification) {
        NSNotificationCenter.defaultCenter().removeObserver(self)
        let storage = NSHTTPCookieStorage.sharedHTTPCookieStorage()
        var newCookies = [NSHTTPCookie]()
        if let cookies = storage.cookies {
            for cookie in cookies {
                if let readOnlyProps = cookie.properties {
                    var props = readOnlyProps as [String: AnyObject]
                    let discard = props[NSHTTPCookieDiscard] as? String
                    if discard == nil || discard! != "TRUE" {
                        props.removeValueForKey(NSHTTPCookieExpires)
                        props[NSHTTPCookieDiscard] = "TRUE"
                        storage.deleteCookie(cookie)
                        if let newCookie = NSHTTPCookie(properties: props) {
                            newCookies.append(newCookie)
                        }
                    }
                }
            }
        }
        for c in newCookies {
            storage.setCookie(c)
        }

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(PrivateBrowsing.cookiesChanged(_:)), name: NSHTTPCookieManagerCookiesChangedNotification, object: nil)
    }
}
