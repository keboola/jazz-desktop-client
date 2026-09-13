// Standalone qualification helper, not a capture client. No field values or password input.
// swiftc owned_synthetic.swift -o /private/owned-synthetic && /private/owned-synthetic --self-test
import AppKit
import ApplicationServices
import Foundation

let textEdit = "com.apple.TextEdit"
func valid(_ frame: CGRect?) -> Bool {
    guard let f = frame else { return false }
    return [f.origin.x, f.origin.y, f.size.width, f.size.height].allSatisfy(\.isFinite)
        && f.size.width > 1 && f.size.height > 1
}
func same(_ a: CGRect?, _ b: CGRect?) -> Bool {
    guard valid(a), valid(b), let a, let b else { return false }
    return zip([a.origin.x,a.origin.y,a.size.width,a.size.height],
               [b.origin.x,b.origin.y,b.size.width,b.size.height]).allSatisfy { abs($0-$1) <= 1 }
}
func checks(expected: Int32, front: Int32?, bundle: String?, owner: Int32?, document: Bool,
            frame: CGRect?, after: CGRect?, frontStable: Bool, focusStable: Bool, screenMatches: Int) -> [String: Bool] {
    ["frontPID": expected > 0 && front == expected, "frontBundle": bundle == textEdit,
     "focusedOwnerPID": owner == expected, "ownedDocumentURL": document,
     "finiteFocusedGeometry": valid(frame), "stableFocusedGeometry": same(frame,after),
     "frontStable": frontStable, "focusStable": focusStable, "uniqueOnScreenGeometry": screenMatches == 1]
}
func emit(_ value: [String: Any]) {
    print(String(data: try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!)
}
if CommandLine.arguments.dropFirst().first == "--self-test" {
    let f=CGRect(x:20,y:30,width:800,height:600)
    func test(front:Int32?=7,bundle:String?=textEdit,owner:Int32?=7,document:Bool=true,
              frame:CGRect?=CGRect(x:20,y:30,width:800,height:600),after:CGRect?=CGRect(x:20,y:30,width:800,height:600),
              stable:Bool=true,focus:Bool=true,matches:Int=1) -> Bool {
        checks(expected:7,front:front,bundle:bundle,owner:owner,document:document,frame:frame,
               after:after,frontStable:stable,focusStable:focus,screenMatches:matches).values.allSatisfy {$0}
    }
    assert(test())
    assert(!test(front:8)); assert(!test(bundle:"com.apple.finder")); assert(!test(owner:8))
    assert(!test(document:false)) // Title/PID alone cannot authorize a private sibling window.
    assert(!test(frame:nil)); assert(!test(frame:CGRect(x:0,y:0,width:0,height:600)))
    assert(!test(frame:CGRect(x:CGFloat.nan,y:0,width:800,height:600)))
    assert(!test(after:f.offsetBy(dx:20,dy:0))); assert(!test(stable:false)); assert(!test(focus:false))
    assert(!test(matches:0)); assert(!test(matches:2)) // Never fall back to a background window.
    emit(["offlineAssertions":13,"passed":true,"nativeCalls":0]); exit(0)
}
let args=CommandLine.arguments
 guard args.count >= 3, ["activate","check","post"].contains(args[1]) else { exit(64) }
let action=args[1], file=URL(fileURLWithPath:args[2]).standardizedFileURL.resolvingSymlinksInPath()
guard file.lastPathComponent.hasPrefix("Jazz-pilot-synthetic-"), file.pathExtension == "txt",
      (try? file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true else {
    emit(["accepted":false,"failure":"owned-file-precondition"]);exit(2)
}
var errors=[String:Int32]()
func get(_ e:AXUIElement,_ key:String) -> CFTypeRef? {
    var v:CFTypeRef?;let status=AXUIElementCopyAttributeValue(e,key as CFString,&v)
    if status != .success { errors[key]=status.rawValue;return nil };return v
}
func element(_ value:CFTypeRef?) -> AXUIElement? {
    guard let value,CFGetTypeID(value)==AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value,to:AXUIElement.self)
}
func owned(_ window:AXUIElement) -> Bool {
    guard let raw=get(window,kAXDocumentAttribute) as? String,let url=URL(string:raw),url.isFileURL else { return false }
    return url.standardizedFileURL.resolvingSymlinksInPath()==file
}
func frame(_ window:AXUIElement?) -> CGRect? {
    guard let window,let p=get(window,kAXPositionAttribute),let s=get(window,kAXSizeAttribute),
          CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
    var point=CGPoint.zero;var size=CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),
          AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else { return nil }
    return CGRect(origin:point,size:size)
}
if action == "activate" {
    // Never steal focus from a native authorization prompt, even one not owned by this trial.
    let ps=Process();ps.executableURL=URL(fileURLWithPath:"/bin/ps");ps.arguments=["-axo","comm="]
    let output=Pipe();ps.standardOutput=output;try! ps.run()
    let names=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
    ps.waitUntilExit()
    guard !names.split(separator:"\n").contains(where:{$0.hasSuffix("/SecurityAgent")}) else {
        emit(["accepted":false,"failure":"native-prompt-present","promptPreserved":true]);exit(3)
    }
    let open=Process();open.executableURL=URL(fileURLWithPath:"/usr/bin/open");open.arguments=["-a","TextEdit",file.path]
    try! open.run();open.waitUntilExit();Thread.sleep(forTimeInterval:0.5)
}
guard let process=NSRunningApplication.runningApplications(withBundleIdentifier:textEdit).first else {
    emit(["accepted":false,"failure":"textedit-not-running"]);exit(4)
}
let expected=args.count > 3 ? Int32(args[3]) ?? 0 : process.processIdentifier
let app=AXUIElementCreateApplication(expected);AXUIElementSetMessagingTimeout(app,1)
if action == "activate" {
    let windows=(get(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter(owned)
    guard windows.count==1 else { emit(["accepted":false,"failure":"owned-window-not-unique","ownedWindowCount":windows.count,"axErrors":errors]);exit(5) }
    _ = AXUIElementPerformAction(windows[0],kAXRaiseAction as CFString)
    _ = process.activate(options:[])
    Thread.sleep(forTimeInterval:0.5)
}
let front=NSWorkspace.shared.frontmostApplication
let focus=element(get(app,kAXFocusedWindowAttribute));let first=frame(focus)
var owner:pid_t=0;if let focus { AXUIElementGetPid(focus,&owner) }
let document=focus.map(owned) ?? false
let screen=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
let matches=screen.filter { row in
    guard row[kCGWindowOwnerPID as String] as? Int32 == expected,
          row[kCGWindowLayer as String] as? Int == 0,
          let bounds=row[kCGWindowBounds as String] as? [String:Any],
          let rect=CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return false }
    return same(first,rect)
}.count
let again=element(get(app,kAXFocusedWindowAttribute));let after=frame(again)
let finalFront=NSWorkspace.shared.frontmostApplication
let result=checks(expected:expected,front:front?.processIdentifier,bundle:front?.bundleIdentifier,
    owner:owner,document:document,frame:first,after:after,
    frontStable:finalFront?.processIdentifier==front?.processIdentifier,
    focusStable:focus != nil && again != nil && CFEqual(focus!,again!),screenMatches:matches)
let accepted=result.values.allSatisfy {$0}
var row:[String:Any]=["accepted":accepted,"action":action,"expectedPID":expected,
    "frontPID":front?.processIdentifier ?? 0,"frontBundle":front?.bundleIdentifier ?? "unknown",
    "focusedOwnerPID":owner,"subchecks":result,"axErrors":errors,"screenGeometryMatches":matches,
    "fieldValuesRead":false,"backgroundCapture":false]
if document,let f=first { row["ownedFocusedFrame"]=[f.origin.x,f.origin.y,f.size.width,f.size.height] }
if accepted && action == "post" {
    guard args.count==5 else { exit(64) }
    let units=Array(("\nSynthetic sample "+args[4]+" — owned Jazz pilot transport test.").utf16)
    let source=CGEventSource(stateID:.hidSystemState)
    guard let down=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:true),
          let up=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:false) else { exit(6) }
    units.withUnsafeBufferPointer { b in
        down.keyboardSetUnicodeString(stringLength:b.count,unicodeString:b.baseAddress!)
        up.keyboardSetUnicodeString(stringLength:b.count,unicodeString:b.baseAddress!)
    }
    down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap);row["syntheticEventPosted"]=true
}
emit(row);exit(accepted ? 0 : 7)
