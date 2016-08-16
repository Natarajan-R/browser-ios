/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#if !NO_FABRIC
    import Crashlytics
#endif
import Shared
import OnePasswordExtension

let kPrefKeyNoScriptOn = "noscript_on"
let kPrefKeyFingerprintProtection = "fingerprintprotection_on"
let kPrefKeyPrivateBrowsingAlwaysOn = "privateBrowsingAlwaysOn"

class BraveSettingsView : AppSettingsTableViewController {

    static var cachedIs3rdPartyPasswordManagerInstalled = false

    var debugToggleItemToTriggerCrashCount = 0

    override func tableView(tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let footerView = InsetLabel(frame: CGRectMake(0, 0, tableView.frame.size.width, 40))
        footerView.leftInset = CGFloat(20)
        footerView.rightInset = CGFloat(10)
        footerView.numberOfLines = 0
        footerView.font = UIFont.boldSystemFontOfSize(13)
        return footerView
    }

    override func tableView(tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    override func viewWillDisappear(animated: Bool) {
        super.viewWillDisappear(animated)

        if BraveApp.getPrefs()?.boolForKey(kPrefKeyFingerprintProtection) ?? false {
            if let tab = getApp().tabManager.selectedTab where tab.getHelper(FingerprintingProtection.self) == nil {
                let fp = FingerprintingProtection(browser: tab)
                tab.addHelper(fp)
            }
        }
    }

    override func generateSettings() -> [SettingSection] {
        let prefs = profile.prefs
        var generalSettings = [
            SearchSetting(settings: self),
            BoolSetting(prefs: prefs, prefKey: BraveUX.PrefKeyIsToolbarHidingEnabled , defaultValue: true, titleText: NSLocalizedString("Hide toolbar when scrolling", comment: ""), statusText: nil, settingDidChange:  { value in
                BraveScrollController.hideShowToolbarEnabled = value

                // Hidden way to trigger a crash for testing
                if (self.debugToggleItemToTriggerCrashCount > 4) {
                    UIAlertView(title: "Trigger a crash for testing", message: "Force a crash?", delegate: self, cancelButtonTitle: "Cancel", otherButtonTitles: "OK").show()
                    self.debugToggleItemToTriggerCrashCount = 0
                } else {
                    self.debugToggleItemToTriggerCrashCount += 1
                }
            }),
            BoolSetting(prefs: prefs, prefKey: "saveLogins", defaultValue: true,
                titleText: NSLocalizedString("Save Logins", comment: "Setting to enable the built-in password manager"))

            ,BoolSetting(prefs: prefs, prefKey: "blockPopups", defaultValue: true,
                titleText: NSLocalizedString("Block Popups", comment: "Setting to enable popup blocking"))
        ]

        if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
            generalSettings.append(BoolSetting(prefs: prefs, prefKey: kPrefKeyTabsBarShowPolicy, defaultValue: true,
                titleText: NSLocalizedString("Show Tabs Bar", comment: "Setting to show/hide the tabs bar"), statusText: nil,
                settingDidChange: { value in
                    getApp().browserViewController.urlBar.updateTabsBarShowing()
                }
            ))
        } else {
            generalSettings.append(TabsBarIPhoneSetting(profile: self.profile))
        }


        #if !DISABLE_THIRD_PARTY_PASSWORD_SNACKBAR
            if BraveSettingsView.cachedIs3rdPartyPasswordManagerInstalled {
                generalSettings.append(ThirdPartyPasswordManagerSetting(profile: self.profile))
            }

            BraveApp.is3rdPartyPasswordManagerInstalled(refreshLookup: true).upon {
                result in
                if result == BraveSettingsView.cachedIs3rdPartyPasswordManagerInstalled {
                    return
                }
                BraveSettingsView.cachedIs3rdPartyPasswordManagerInstalled = result

                // TODO: if PW manager is removed, settings must be opening a 2nd time for setting to disappear.
                if result {
                    postAsyncToMain(0) { // move from db thread back to main
                        generalSettings.append(ThirdPartyPasswordManagerSetting(profile: self.profile))
                        self.settings[0] = SettingSection(title: NSAttributedString(string: NSLocalizedString("General", comment: "General settings section title")), children: generalSettings)
                        let range = NSMakeRange(0, 1)
                        let section = NSIndexSet(indexesInRange: range)
                        self.tableView.reloadSections(section, withRowAnimation: .Automatic)
                    }
                }
            }
        #endif


        settings += [
            SettingSection(title: NSAttributedString(string: NSLocalizedString("General", comment: "General settings section title")), children: generalSettings),
            SettingSection(title: NSAttributedString(string: NSLocalizedString("Privacy", comment: "Privacy settings section title")), children:
                [ClearPrivateDataSetting(settings: self), CookieSetting(profile: self.profile),
                    BoolSetting(prefs: prefs, prefKey: kPrefKeyPrivateBrowsingAlwaysOn, defaultValue: false, titleText: NSLocalizedString("Private Browsing Only", comment: "Setting to keep app in private mode"), statusText: nil, settingDidChange: { isOn in
                        if !isOn {
                            return
                        }
                        if #available(iOS 9, *) {
                            if !PrivateBrowsing.singleton.isOn {
                                getApp().browserViewController.switchToPrivacyMode()
                                getApp().tabManager.addTabAndSelect(isPrivate: true)
                            }
                        }
                    })]
            ),
            SettingSection(title: NSAttributedString(string: NSLocalizedString("Brave Shield Defaults", comment: "Section title for adbblock, tracking protection, HTTPS-E, and cookies")), children:
                [BoolSetting(prefs: prefs, prefKey: AdBlocker.prefKey, defaultValue: true, titleText: NSLocalizedString("Block Ads and Tracking", comment: "")),
                    BoolSetting(prefs: prefs, prefKey: HttpsEverywhere.prefKey, defaultValue: true, titleText: NSLocalizedString("HTTPS Everywhere", comment: "")),
                    BoolSetting(prefs: prefs, prefKey: SafeBrowsing.prefKey, defaultValue: true, titleText: NSLocalizedString("Block Phishing and Malware", comment: "")),
                    BoolSetting(prefs: prefs, prefKey: kPrefKeyNoScriptOn, defaultValue: false, titleText: NSLocalizedString("Block Scripts", comment: "")),
                    BoolSetting(prefs: prefs, prefKey: kPrefKeyFingerprintProtection, defaultValue: false, titleText: NSLocalizedString("Fingerprinting Protection", comment: ""))
                ])]

        //#if !DISABLE_INTRO_SCREEN
        settings += [
            SettingSection(title: NSAttributedString(string: NSLocalizedString("Support", comment: "Support section title")), children: [
                ShowIntroductionSetting(settings: self),
                BraveSupportLinkSetting(),
                BravePrivacyPolicySetting(), BraveTermsOfUseSetting(),
                ])]
        //#endif
        settings += [
            SettingSection(title: NSAttributedString(string: NSLocalizedString("About", comment: "About settings section title")), children: [
                VersionSetting(settings: self),
                ])
        ]
        return settings
    }
}

extension BraveSettingsView : UIAlertViewDelegate {
    func alertView(alertView: UIAlertView, didDismissWithButtonIndex buttonIndex: Int) {
        if buttonIndex == alertView.cancelButtonIndex {
            return
        }
        #if !NO_FABRIC
            Crashlytics.sharedInstance().crash()
        #endif
    }
}

// Opens the search settings pane
class ThirdPartyPasswordManagerSetting: PicklistSettingMainItem<String> {

    static var currentSetting: (displayName: String, cellLabel: String, prefId: Int)?

    private static let _prefName = kPrefName3rdPartyPasswordShortcutEnabled
    private static let _options =  [
        Choice<String> { ThirdPartyPasswordManagers.UseBuiltInInstead },
        Choice<String> { ThirdPartyPasswordManagers.OnePassword },
        Choice<String> { ThirdPartyPasswordManagers.LastPass }
    ]

    static func setupOnAppStart() {
        let current = BraveApp.getPrefs()?.intForKey(_prefName) ?? 0
        switch Int(current) {
        case ThirdPartyPasswordManagers.OnePassword.prefId:
            currentSetting = ThirdPartyPasswordManagers.OnePassword
        case ThirdPartyPasswordManagers.LastPass.prefId:
            currentSetting = ThirdPartyPasswordManagers.LastPass
        default:
            currentSetting = ThirdPartyPasswordManagers.UseBuiltInInstead
        }
    }

    init(profile: Profile) {
        super.init(profile: profile, displayName: "", prefName: ThirdPartyPasswordManagerSetting._prefName, options: ThirdPartyPasswordManagerSetting._options)
        picklistFooterMessage = NSLocalizedString("Show a prompt to open your password manager when the current page has a login form.", comment: "Footer message on picker for 3rd party password manager setting")
    }

    override func picklistSetting(setting: PicklistSettingOptionsView, pickedOptionId: Int) {
        super.picklistSetting(setting, pickedOptionId: pickedOptionId)
        ThirdPartyPasswordManagerSetting.setupOnAppStart()
    }

    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("3rd-party password manager", comment: "Setting to enable the built-in password manager"), attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor, NSFontAttributeName: UIFont.systemFontOfSize(14)])
    }
}


// Opens the search settings pane
class CookieSetting: PicklistSettingMainItem<UInt> {
    private static let _prefName = "braveAcceptCookiesPref"
    private static let _options =  [
        Choice<UInt> { (displayName: NSLocalizedString("Block 3rd party cookies", comment: "cookie settings option"), object: UInt(NSHTTPCookieAcceptPolicy.OnlyFromMainDocumentDomain.rawValue), optionId: 0) },
        Choice<UInt> { (displayName: NSLocalizedString("Block all cookies", comment: "cookie settings option"), object: UInt(NSHTTPCookieAcceptPolicy.Never.rawValue), optionId: 1) },
        Choice<UInt> { (displayName: NSLocalizedString("Don't block cookies", comment: "cookie settings option"), object: UInt( NSHTTPCookieAcceptPolicy.Always.rawValue), optionId: 2) }
    ]

    static func setPolicyFromOptionId(optionId: Int) {
        for option in _options {
            if option.item().optionId == optionId {
                NSHTTPCookieStorage.sharedHTTPCookieStorage().cookieAcceptPolicy = NSHTTPCookieAcceptPolicy.init(rawValue: option.item().object)!
            }
        }
    }

    static func setupOnAppStart() {
        let current = BraveApp.getPrefs()?.intForKey(_prefName) ?? 0
        setPolicyFromOptionId(Int(current))
    }

    init(profile: Profile) {
        super.init(profile: profile, displayName: NSLocalizedString("Cookie Control", comment: "Cookie settings option title"), prefName: CookieSetting._prefName, options: CookieSetting._options)
    }

    override func picklistSetting(setting: PicklistSettingOptionsView, pickedOptionId: Int) {
        super.picklistSetting(setting, pickedOptionId: pickedOptionId)
        CookieSetting.setPolicyFromOptionId(pickedOptionId)
    }
}

// Opens the search settings pane
class TabsBarIPhoneSetting: PicklistSettingMainItem<Int> {
    private static func getOptions() -> [Choice<Int>] {
        let opt = [
            Choice<Int> { (displayName: NSLocalizedString("Never show", comment: "tabs bar show/hide option"), object: TabsBarShowPolicy.Never.rawValue, optionId: 0) },
            Choice<Int> { (displayName: NSLocalizedString("Always show", comment: "tabs bar show/hide option"), object: TabsBarShowPolicy.Always.rawValue, optionId: 1) },
            Choice<Int> { (displayName: NSLocalizedString("Show in landscape only", comment: "tabs bar show/hide option"), object: TabsBarShowPolicy.LandscapeOnly.rawValue, optionId: 2) }
        ]
        return opt

    }

    init(profile: Profile) {
        super.init(profile: profile, displayName: NSLocalizedString("Show Tabs Bar", comment:"tabs bar show/hide setting title"), prefName: kPrefKeyTabsBarShowPolicy, options: TabsBarIPhoneSetting.getOptions())
    }

    override func picklistSetting(setting: PicklistSettingOptionsView, pickedOptionId: Int) {
        super.picklistSetting(setting, pickedOptionId: pickedOptionId)
        getApp().browserViewController.urlBar.updateTabsBarShowing()
    }

    override func getCurrent() -> Int {
        return Int(BraveApp.getPrefs()?.intForKey(prefName) ?? Int32(kPrefKeyTabsBarOnDefaultValue.rawValue))
    }
}




// Clear all stored passwords. This will clear SQLite storage and the system shared credential storage.
class PasswordsClearable: Clearable {
    let profile: Profile
    init(profile: Profile) {
        self.profile = profile
    }

    var label: String {
        return NSLocalizedString("Saved Logins", tableName: "ClearPrivateData", comment: "Settings item for clearing passwords and login data")
    }

    func clear() -> Success {
        // Clear our storage
        return profile.logins.removeAll() >>== { res in
            let storage = NSURLCredentialStorage.sharedCredentialStorage()
            let credentials = storage.allCredentials
            for (space, credentials) in credentials {
                for (_, credential) in credentials {
                    storage.removeCredential(credential, forProtectionSpace: space)
                }
            }
            return succeed()
        }
    }
}

class BraveSupportLinkSetting: Setting{
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Report a bug", comment: "Show mail composer to report a bug."), attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }


    override func onClick(navigationController: UINavigationController?) {
        UIApplication.sharedApplication().openURL(NSURL(string: "mailto:support+ios@brave.com")!)
    }

    override func onConfigureCell(cell: UITableViewCell) {
        super.onConfigureCell(cell)
        let g = UILongPressGestureRecognizer(target: self, action: #selector(longPress))
        cell.addGestureRecognizer(g)
    }

    @objc func longPress(g: UILongPressGestureRecognizer) {
        if g.state != .Began {
            return
        }
        // Use this to experiment with fixing bug where page is partially rendered
        // TODO use this to add special debugging functions

        #if FLEX_ON
           FLEXManager.sharedManager().showExplorer()
        #endif
    }

}

class BravePrivacyPolicySetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Privacy Policy", comment: "Show Brave Browser Privacy Policy page from the Privacy section in the settings."), attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }

    override var url: NSURL? {
        return NSURL(string: "https://www.brave.com/privacy_ios")
    }

    override func onClick(navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

class BraveTermsOfUseSetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Terms of Use", comment: "Show Brave Browser TOS page from the Privacy section in the settings."), attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }

    override var url: NSURL? {
        return NSURL(string: "https://www.brave.com/terms_of_use")
    }

    override func onClick(navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}



