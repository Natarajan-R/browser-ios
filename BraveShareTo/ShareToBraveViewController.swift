
import UIKit
import Social
import MobileCoreServices

extension NSObject {
    func callSelector(selector: Selector, object: AnyObject?, delay: NSTimeInterval) {
        let delay = delay * Double(NSEC_PER_SEC)
        let time = dispatch_time(DISPATCH_TIME_NOW, Int64(delay))
        dispatch_after(time, dispatch_get_main_queue(), {
            NSThread.detachNewThreadSelector(selector, toTarget:self, withObject: object)
        })
    }
}

class ShareToBraveViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool {
        return true
    }

    override func didSelectPost() {
        return
    }

    override func configurationItems() -> [AnyObject]! {
        let item: NSExtensionItem = extensionContext!.inputItems[0] as! NSExtensionItem
        let itemProvider: NSItemProvider = item.attachments![0] as! NSItemProvider
        let type = kUTTypeURL as String

        if itemProvider.hasItemConformingToTypeIdentifier(type) {
            itemProvider.loadItemForTypeIdentifier(type, options: nil, completionHandler: {
                (urlItem, error) in
                guard let url = (urlItem as! NSURL).absoluteString.stringByAddingPercentEncodingWithAllowedCharacters(NSCharacterSet.alphanumericCharacterSet()),
                 let braveUrl = NSURL(string: "brave://open-url?url=\(url)") else { return }

                // From http://stackoverflow.com/questions/24297273/openurl-not-work-in-action-extension
                var responder = self as UIResponder?
                while (responder != nil) {
                    if responder!.respondsToSelector(#selector(UIApplication.openURL(_:))) {
                        responder!.callSelector(#selector(UIApplication.openURL(_:)), object: braveUrl, delay: 0)
                    }
                    responder = responder!.nextResponder()
                }

                dispatch_after(
                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        Int64(0.1 * Double(NSEC_PER_SEC))
                    ),
                    dispatch_get_main_queue(), { self.cancel() })
            })
        }

        return []
    }

    override func viewDidAppear(animated: Bool) {
        // Stop keyboard from showing
        textView.resignFirstResponder()
        textView.editable = false

        super.viewDidAppear(animated)
    }

    override func willMoveToParentViewController(parent: UIViewController?) {
        view.alpha = 0
    }
}
