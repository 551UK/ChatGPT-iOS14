@_silgen_name("$s9GeckoViewAAC7sessionAA0A7SessionCSgvg")
private func CGGeckoViewSession(_ view: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?

@_silgen_name("$s9GeckoView0A7SessionC4load_5flagsySS_SitF")
private func CGGeckoSessionLoad(_ url: String, _ flags: Int, _ session: UnsafeMutableRawPointer)

@_cdecl("CGRunChatGPTDotScript")
public func CGRunChatGPTDotScript(_ rawView: UnsafeMutableRawPointer?) -> Int32 {
    guard let rawView, let session = CGGeckoViewSession(rawView) else { return 0 }

    let script = "javascript:(()=>{const e=document.querySelector('#prompt-textarea');if(!e)return;e.focus();document.execCommand('insertText',false,'.');setTimeout(()=>e.blur(),25)})()"
    CGGeckoSessionLoad(script, 0, session)
    return 1
}
