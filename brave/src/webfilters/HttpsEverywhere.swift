/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */
import SQLite

private let _singleton = HttpsEverywhere()

class HttpsEverywhere {
    static let kNotificationDataLoaded = "kNotificationDataLoaded"
    static let prefKey = "braveHttpsEverywhere"
    static let prefKeyDefaultValue = true
    static let dataVersion = "5.1.9"
    var isNSPrefEnabled = true
    var cppInterface = HttpEverywhereCpp()

    lazy var networkFileLoader: NetworkDataFileLoader = {
        let targetsDataUrl = NSURL(string: "https://s3.amazonaws.com/https-everywhere-data/\(dataVersion)/httpse.sqlite")!
        let dataFile = "httpse-\(dataVersion).sqlite"
        let loader = NetworkDataFileLoader(url: targetsDataUrl, file: dataFile, localDirName: "https-everywhere-data")
        loader.delegate = self

        self.runtimeDebugOnlyTestVerifyResourcesLoaded()

        return loader
    }()

    class var singleton: HttpsEverywhere {
        return _singleton
    }

    private init() {
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(HttpsEverywhere.prefsChanged(_:)), name: NSUserDefaultsDidChangeNotification, object: nil)
        updateEnabledState()
    }


    func loadSqlDb() {
        // synchronize code from this point on.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard let path = networkFileLoader.pathToExistingDataOnDisk() else { return }
        cppInterface.setDataFile(path)
        NSNotificationCenter.defaultCenter().postNotificationName(HttpsEverywhere.kNotificationDataLoaded, object: self)

        assert(cppInterface.hasDataFile())
    }

    func updateEnabledState() {
        // synchronize code from this point on.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        isNSPrefEnabled = BraveApp.getPrefs()?.boolForKey(HttpsEverywhere.prefKey) ?? true
    }

    @objc func prefsChanged(info: NSNotification) {
        updateEnabledState()
    }

    func tryRedirectingUrl(url: NSURL) -> NSURL? {
        if url.scheme.startsWith("https") {
            return nil
        }

        let ignoredlist = [
            "m.slashdot.org" // see https://github.com/brave/browser-ios/issues/104
        ]
        for item in ignoredlist {
            if url.absoluteString.contains(item) {
                return nil
            }
        }

        let result = cppInterface.tryRedirectingUrl(url)
        if result.isEmpty {
            return nil
        } else {
            return NSURL(string: result)
        }
    }
}

extension HttpsEverywhere: NetworkDataFileLoaderDelegate {
    func fileLoader(loader: NetworkDataFileLoader, setDataFile data: NSData?) {
        if data != nil {
            loadSqlDb()
        }
    }

    func fileLoaderHasDataFile(_: NetworkDataFileLoader) -> Bool {
        return cppInterface.hasDataFile()
    }
}


// Build in test cases, swift compiler is mangling the test cases in HttpsEverywhereTests.swift and they are failing. The compiler is falsely casting  AnyObjects to XCUIElement, which then breaks the runtime tests, I don't have time to look at this further ATM.
extension HttpsEverywhere {
    private func runtimeDebugOnlyTestDomainsRedirected() {
        #if DEBUG
            let urls = ["thestar.com", "thestar.com/", "www.thestar.com", "apple.com", "xkcd.com"]
            for url in urls {
                guard let _ =  HttpsEverywhere.singleton.tryRedirectingUrl(NSURL(string: "http://" + url)!) else {
                    BraveApp.showErrorAlert(title: "Debug Error", error: "HTTPS-E validation failed on url: \(url)")
                    return
                }
            }

            let url = HttpsEverywhere.singleton.tryRedirectingUrl(NSURL(string: "http://www.googleadservices.com/pagead/aclk?sa=L&ai=CD0d/")!)
            if url == nil || !url!.absoluteString.hasSuffix("?sa=L&ai=CD0d/") {
                BraveApp.showErrorAlert(title: "Debug Error", error: "HTTPS-E validation failed for url args")
            }
        #endif
    }

    private func runtimeDebugOnlyTestVerifyResourcesLoaded() {
        #if DEBUG
            delay(10) {
                if !self.cppInterface.hasDataFile() {
                    BraveApp.showErrorAlert(title: "Debug Error", error: "HTTPS-E didn't load")
                } else {
                    self.runtimeDebugOnlyTestDomainsRedirected()
                }
            }
        #endif
    }
}
