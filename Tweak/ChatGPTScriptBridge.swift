private class CGOpaqueGeckoSession {}
private class CGOpaqueGeckoView {}

// Bind to Reynard's existing public GeckoView Swift symbols without importing
// the stripped GeckoView.swiftmodule from the release IPA. Declaring these as
// instance methods is important: Swift passes `self` with its method calling
// convention rather than as a normal C-style argument.
extension CGOpaqueGeckoView {
    @_silgen_name("$s9GeckoViewAAC7sessionAA0A7SessionCSgvg")
    func cgSession() -> CGOpaqueGeckoSession?
}

extension CGOpaqueGeckoSession {
    @_silgen_name("$s9GeckoView0A7SessionC4load_5flagsySS_SitF")
    func cgLoad(_ url: String, flags: Int)
}

@_cdecl("CGRunChatGPTDotScript")
public func CGRunChatGPTDotScript(_ rawView: UnsafeMutableRawPointer?) -> Int32 {
    guard let rawView else { return 0 }

    let geckoView = Unmanaged<CGOpaqueGeckoView>.fromOpaque(rawView).takeUnretainedValue()
    guard let session = geckoView.cgSession() else { return 0 }

    let script = "javascript:(()=>{const e=document.querySelector('#prompt-textarea');if(!e)return;e.focus();document.execCommand('insertText',false,'.');setTimeout(()=>e.blur(),25)})()"
    session.cgLoad(script, flags: 0)
    return 1
}
