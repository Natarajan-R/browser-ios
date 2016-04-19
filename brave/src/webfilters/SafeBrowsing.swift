/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared

private let _singleton = SafeBrowsing()

class SafeBrowsing {
    static let prefKey = "braveSafeBrowsing"
    static let prefKeyDefaultValue = true
    static let dataVersion = "1"

    lazy var abpFilterLibWrapper: ABPFilterLibWrapper = { return ABPFilterLibWrapper() }()

    lazy var networkFileLoader: NetworkDataFileLoader = {
        let dataUrl = NSURL(string: "https://s3.amazonaws.com/safe-browsing-data/\(dataVersion)/SafeBrowsingData.dat")!
        let dataFile = "safe-browsing-data-\(dataVersion).dat"
        let loader = NetworkDataFileLoader(url: dataUrl, file: dataFile, localDirName: "safe-browsing-data")
        loader.delegate = self
        return loader
    }()

    var fifoCacheOfUrlsChecked = FifoDict()
    var isEnabled = true

    private init() {
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(SafeBrowsing.prefsChanged(_:)), name: NSUserDefaultsDidChangeNotification, object: nil)
        updateEnabledState()
    }

    class var singleton: SafeBrowsing {
        return _singleton
    }

    func updateEnabledState() {
        isEnabled = BraveApp.getPrefs()?.boolForKey(SafeBrowsing.prefKey) ?? SafeBrowsing.prefKeyDefaultValue
    }

    @objc func prefsChanged(info: NSNotification) {
        updateEnabledState()
    }

    func shouldBlock(request: NSURLRequest) -> Bool {
        // synchronize code from this point on.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        if !isEnabled {
            return false
        }

        if request.mainDocumentURL?.absoluteString.startsWith(WebServer.sharedInstance.base) ?? false ||
            request.URL?.absoluteString.startsWith(WebServer.sharedInstance.base) ?? false {
            return false
        }

        guard let url = request.URL else { return false }

        let host: String = request.mainDocumentURL?.host ?? url.host ?? ""

        // A cache entry is like: fifoOfCachedUrlChunks[0]["www.microsoft.com_http://some.url"] = true/false for blocking
        let key = "\(host)_" + url.absoluteString

        if let checkedItem = fifoCacheOfUrlsChecked.getItem(key) {
            if checkedItem === NSNull() {
                return false
            } else {
                return checkedItem as! Bool
            }
        }

        let isBlocked = abpFilterLibWrapper.isBlockedIgnoringType(url.absoluteString, mainDocumentUrl: host)

        fifoCacheOfUrlsChecked.addItem(key, value: isBlocked)
        
       // #if LOG_AD_BLOCK
            if isBlocked {
                print("safe browsing blocked \(url.absoluteString)")
            }
       // #endif
        
        return isBlocked
    }
}

extension SafeBrowsing: NetworkDataFileLoaderDelegate {

    func fileLoader(_: NetworkDataFileLoader, setDataFile data: NSData?) {
        abpFilterLibWrapper.setDataFile(data)
    }

    func fileLoaderHasDataFile(_: NetworkDataFileLoader) -> Bool {
        return abpFilterLibWrapper.hasDataFile()
    }
}
