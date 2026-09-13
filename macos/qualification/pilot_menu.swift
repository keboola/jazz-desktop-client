// Qualification-only exact-PID/app menu control. No Keychain or input-value access.
import AppKit
import ApplicationServices
import Foundation

func sameAppPath(_ actual: URL?, _ expected: URL) -> Bool {
    // Normalize BOTH operands in Foundation: Darwin /tmp and /private/tmp aliases differ
    // from Python Path.resolve(). Never compare one normalized path to a foreign literal.
    actual?.resolvingSymlinksInPath().standardizedFileURL.path
        == expected.resolvingSymlinksInPath().standardizedFileURL.path
}
func emit(_ value: [String: Any]) {
    print(String(data:try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!)
}
let args=CommandLine.arguments
if args.dropFirst().first == "--self-test" {
    // Resolution follows the filesystem; use an existing, exclusively named owned directory.
    let a=URL(fileURLWithPath:"/tmp/Jazz-menu-\(UUID().uuidString).app",isDirectory:true)
    try! FileManager.default.createDirectory(at:a,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let b=URL(fileURLWithPath:"/private"+a.path,isDirectory:true)
    assert(sameAppPath(a,b));assert(sameAppPath(b,a));assert(sameAppPath(a,a))
    assert(!sameAppPath(nil,a))
    assert(!sameAppPath(URL(fileURLWithPath:"/Applications/Jazz Capture.app"),a))
    assert(!sameAppPath(URL(fileURLWithPath:"/tmp/other/Jazz-menu-regression.app"),a))
    try! FileManager.default.removeItem(at:a)
    emit(["offlineAssertions":6,"passed":true,"nativeCaptureOrAXCalls":0]);exit(0)
}
guard args.count==4,let pid=Int32(args[1]),pid>0,
      ["inspect","Start / Resume","Pause","Stop","Quit isolated pilot"].contains(args[2]) else { exit(64) }
let action=args[2],expected=URL(fileURLWithPath:args[3],isDirectory:true)
let process=NSRunningApplication(processIdentifier:pid)
let identity=["processExists":process != nil,"bundleIdMatches":process?.bundleIdentifier=="dev.jazz.capture.direct-pilot",
              "bundlePathMatches":sameAppPath(process?.bundleURL,expected)]
guard identity.values.allSatisfy({$0}) else { emit(["accepted":false,"stage":"identity","subchecks":identity]);exit(2) }
let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,2)
var errors=[String:Int32]()
func get(_ e:AXUIElement,_ key:String) -> CFTypeRef? {
    var v:CFTypeRef?;let status=AXUIElementCopyAttributeValue(e,key as CFString,&v)
    if status != .success { errors[key]=status.rawValue;return nil };return v
}
guard let extras=get(app,"AXExtrasMenuBar"),CFGetTypeID(extras)==AXUIElementGetTypeID() else {
    emit(["accepted":false,"stage":"extras-menu","subchecks":identity,"axErrors":errors]);exit(5)
}
var queue=[(unsafeBitCast(extras,to:AXUIElement.self),0)];var count=0;var matches=[AXUIElement]();var titles=[String]()
while !queue.isEmpty && count<64 {
    let (e,depth)=queue.removeFirst();count += 1
    let title=get(e,kAXTitleAttribute) as? String ?? ""
    if !title.isEmpty { titles.append(title) }
    if title.hasPrefix(action) { matches.append(e) }
    if depth<5,let children=get(e,kAXChildrenAttribute) as? [AXUIElement] { queue += children.map {($0,depth+1)} }
}
if action=="inspect" { emit(["accepted":true,"stage":"inspect","titles":titles,"axErrors":errors]);exit(0) }
guard matches.count==1 else { emit(["accepted":false,"stage":"action-match","matches":matches.count,"titles":titles,"axErrors":errors]);exit(6) }
let status=AXUIElementPerformAction(matches[0],kAXPressAction as CFString)
emit(["accepted":status == .success,"stage":"press","action":action,"status":status.rawValue,"subchecks":identity])
exit(status == .success ? 0 : 7)
