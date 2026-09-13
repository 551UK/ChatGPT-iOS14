import Foundation
import UIKit
import GeckoView

@_cdecl("CGRunChatGPTDotScript")
public func CGRunChatGPTDotScript(_ rawView: UnsafeMutableRawPointer?) -> Int32 {
    guard let rawView else { return 0 }
    let object = Unmanaged<AnyObject>.fromOpaque(rawView).takeUnretainedValue()
    guard let geckoView = object as? GeckoView, let session = geckoView.session else { return 0 }
    let script = "javascript:(()=>{const e=document.querySelector('#prompt-textarea');if(!e)return;e.focus();document.execCommand('insertText',false,'.');setTimeout(()=>e.blur(),25)})()"
    session.load(script)
    return 1
}
