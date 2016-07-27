/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Storage

public struct BookmarksNotifications {
    public static let SwitchEditMode = "SwitchEditMode"
}

struct SiteTableViewControllerUX {
    static let HeaderHeight = CGFloat(25)
    static let RowHeight = CGFloat(58)
    static let HeaderBorderColor = UIColor(rgb: 0xCFD5D9).colorWithAlphaComponent(0.8)
    static let HeaderTextColor = UIAccessibilityDarkerSystemColorsEnabled() ? UIColor.blackColor() : UIColor(rgb: 0x232323)
    static let HeaderBackgroundColor = UIColor(rgb: 0xECF0F3).colorWithAlphaComponent(0.3)
    static let HeaderFont = UIFont.systemFontOfSize(12, weight: UIFontWeightMedium)
    static let HeaderTextMargin = CGFloat(10)
}

class SiteTableViewHeader : UITableViewHeaderFooterView {
    // I can't get drawRect to play nicely with the glass background. As a fallback
    // we just use views for the top and bottom borders.
    let topBorder = UIView()
    let bottomBorder = UIView()
    let titleLabel = UILabel()

    override var textLabel: UILabel? {
        return titleLabel
    }

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)

        topBorder.backgroundColor = UIColor.whiteColor()
        bottomBorder.backgroundColor = SiteTableViewControllerUX.HeaderBorderColor
        contentView.backgroundColor = UIColor.whiteColor()

        titleLabel.font = DynamicFontHelper.defaultHelper.DeviceFontSmallLight
        titleLabel.textColor = SiteTableViewControllerUX.HeaderTextColor
        titleLabel.textAlignment = .Left

        addSubview(topBorder)
        addSubview(bottomBorder)
        contentView.addSubview(titleLabel)

        topBorder.snp_makeConstraints { make in
            make.left.right.equalTo(self)
            make.top.equalTo(self).offset(-0.5)
            make.height.equalTo(0.5)
        }

        bottomBorder.snp_makeConstraints { make in
            make.left.right.bottom.equalTo(self)
            make.height.equalTo(0.5)
        }

        // A table view will initialize the header with CGSizeZero before applying the actual size. Hence, the label's constraints
        // must not impose a minimum width on the content view.
        titleLabel.snp_makeConstraints { make in
            make.left.equalTo(contentView).offset(SiteTableViewControllerUX.HeaderTextMargin).priority(999)
            make.right.equalTo(contentView).offset(-SiteTableViewControllerUX.HeaderTextMargin).priority(999)
            make.centerY.equalTo(contentView)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/**
 * Provides base shared functionality for site rows and headers.
 */
class SiteTableViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    private let CellIdentifier = "CellIdentifier"
    private let HeaderIdentifier = "HeaderIdentifier"
    var profile: Profile! {
        didSet {
            reloadData()
        }
    }
    
    var iconForSiteId = [Int : Favicon]()
    var data: Cursor<Site> = Cursor<Site>(status: .Success, msg: "No data set")
    var tableView = UITableView()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(tableView)
        tableView.snp_makeConstraints { make in
            make.edges.equalTo(self.view)
            return
        }

        tableView.delegate = self
        tableView.dataSource = self
        tableView.registerClass(HistoryTableViewCell.self, forCellReuseIdentifier: CellIdentifier)
        tableView.registerClass(SiteTableViewHeader.self, forHeaderFooterViewReuseIdentifier: HeaderIdentifier)
        tableView.layoutMargins = UIEdgeInsetsZero
        tableView.keyboardDismissMode = UIScrollViewKeyboardDismissMode.OnDrag
        tableView.backgroundColor = UIConstants.PanelBackgroundColor
        tableView.separatorColor = UIConstants.SeparatorColor
        tableView.accessibilityIdentifier = "SiteTable"

        if #available(iOS 9, *) {
            tableView.cellLayoutMarginsFollowReadableWidth = false
        }
        

        // Set an empty footer to prevent empty cells from appearing in the list.
        tableView.tableFooterView = UIView()
        
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(switchTableEditingMode), name: BookmarksNotifications.SwitchEditMode, object: nil)

    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: BookmarksNotifications.SwitchEditMode, object: nil)

        // The view might outlive this view controller thanks to animations;
        // explicitly nil out its references to us to avoid crashes. Bug 1218826.
        tableView.dataSource = nil
        
        tableView.delegate = nil
        
    }
    
   
    func switchTableEditingMode() {
        //unwoned self is generally unnecessary here since the block is not going to create retention loops,
        //but useful to include considering UIViews may get deallocated unexpectedly
        dispatch_async(dispatch_get_main_queue()) { [unowned self] in
            self.tableView.editing = !self.tableView.editing
        }

    }

    func reloadData() {
        if data.status != .Success {
            print("Err: \(data.statusMessage)", terminator: "\n")
        } else {
            //ensure reloadData call is in main queue
            //unwoned self is generally unnecessary here since the block is not going to create retention loops,
            //but useful to include considering UIViews may get deallocated unexpectedly
            dispatch_async(dispatch_get_main_queue()) { [unowned self] in
                self.tableView.reloadData()
            }
        }
    }

    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return data.count
    }

    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellWithIdentifier(CellIdentifier, forIndexPath: indexPath)
        if self.tableView(tableView, hasFullWidthSeparatorForRowAtIndexPath: indexPath) {
            cell.separatorInset = UIEdgeInsetsZero
        }
        
        cell.gestureRecognizers?.forEach { cell.removeGestureRecognizer($0) }
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(longPressOnCell))
        cell.addGestureRecognizer(lp)

        return cell
    }
    
    func tableView(tableView: UITableView, moveRowAtIndexPath sourceIndexPath: NSIndexPath, toIndexPath destinationIndexPath: NSIndexPath) {
        // update your model
    }
    
    func tableView(tableView: UITableView, canMoveRowAtIndexPath indexPath: NSIndexPath) -> Bool {
        // Return NO if you do not want the item to be re-orderable.
        return true
    }

    func tableView(tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return tableView.dequeueReusableHeaderFooterViewWithIdentifier(HeaderIdentifier)
    }

    func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return SiteTableViewControllerUX.HeaderHeight
    }

    func tableView(tableView: UITableView, heightForRowAtIndexPath indexPath: NSIndexPath) -> CGFloat {
        return SiteTableViewControllerUX.RowHeight
    }

    func tableView(tableView: UITableView, hasFullWidthSeparatorForRowAtIndexPath indexPath: NSIndexPath) -> Bool {
        return false
    }

    @objc func longPressOnCell(gesture: UILongPressGestureRecognizer) {
        if gesture.state != .Began {
            return
        }

        guard let cell = gesture.view as? UITableViewCell else { return }
        var url:NSURL? = nil

        if let bookmarks = self as? BookmarksPanel,
            source = bookmarks.source,
            let indexPath = tableView.indexPathForCell(cell) {
            let bookmark = source.current[indexPath.row]
            if let b = bookmark as? BookmarkItem {
                url = NSURL(string: b.url)
            }

        } else if let path = cell.detailTextLabel?.text {
            url = NSURL(string: path)
        }

        guard let _ = url else { return }

        let tappedElement = ContextMenuHelper.Elements(link: url, image: nil)
        var p = getApp().window!.convertPoint(cell.center, fromView:cell.superview!)
        p.x += cell.frame.width * 0.33
        getApp().browserViewController.showContextMenu(elements: tappedElement, touchPoint: p)
    }
}
