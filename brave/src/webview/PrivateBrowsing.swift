import Shared

private let _singleton = PrivateBrowsing()

class PrivateBrowsing {
    class var singleton: PrivateBrowsing {
        return _singleton
    }

    var isOn = false

    var nonprivateCookies = [NSHTTPCookie: Bool]()

    // On startup we are no longer in private mode, if there is a .public cookies file, it means app was killed in private mode, so restore the cookies file
    func startupCheckIfKilledWhileInPBMode() {
        webkitDirLocker(lock: false)

        CacheClearable().clear()
        CookiesClearable().clear()

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
    }

    func exit() {
        if !isOn {
            return
        }

        isOn = false

        webkitDirLocker(lock: false)

        BraveApp.setupCacheDefaults()
        NSNotificationCenter.defaultCenter().removeObserver(self)

        CacheClearable().clear()
        CookiesClearable().clear()

        cookiesFileDiskOperation(.DeletePublicBackup)
        let storage = NSHTTPCookieStorage.sharedHTTPCookieStorage()
        for cookie in nonprivateCookies {
            storage.setCookie(cookie.0)
        }
        nonprivateCookies = [NSHTTPCookie: Bool]()
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
