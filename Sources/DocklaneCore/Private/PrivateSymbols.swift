import AppKit
import ApplicationServices

/// The only place Docklane touches Apple-private functions.
///
/// Every symbol is resolved at run time with `dlsym`. If a macOS release removes one, the
/// matching property is `nil` and only the feature built on it degrades; Docklane itself keeps
/// launching (a directly linked missing symbol would crash it at startup).
///
/// | Symbol | Used for |
/// |---|---|
/// | `_AXUIElementGetWindow` | window number of an Accessibility element |
/// | `_AXUIElementCreateWithRemoteToken` | Accessibility element of a window on another Space |
/// | `CGSMainConnectionID` | WindowServer connection for the calls below |
/// | `CGSHWCaptureWindowList` | image of a window ScreenCaptureKit refuses (other Space) |
/// | `_SLPSSetFrontProcessWithOptions` | bring one exact window forward, switching Space |
/// | `SLPSPostEventRecordTo` | make that window key |
/// | `SLSCopyManagedDisplaySpaces` | list desktops and full-screen spaces |
/// | `SLSCopySpacesForWindows` | which space a window is on |
/// | `SLSGetActiveSpace` | the space currently shown |
/// | `GetProcessForPID` | process serial number for the SkyLight calls |
public enum PrivateSymbols {
    public typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    public typealias AXCreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    public typealias MainConnectionID = @convention(c) () -> Int32
    public typealias HWCaptureWindowList = @convention(c) (
        Int32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32
    ) -> Unmanaged<CFArray>?
    public typealias SetFrontProcessWithOptions = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
    public typealias PostEventRecordTo = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError
    public typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    public typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    public typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
    public typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    nonisolated(unsafe) private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
    )

    private static func resolve<T>(_ name: String) -> T? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let address = dlsym(rtldDefault, name) ?? skyLight.flatMap({ dlsym($0, name) }) else {
            return nil
        }
        return unsafeBitCast(address, to: T.self)
    }

    public static let axGetWindow: AXGetWindow? = resolve("_AXUIElementGetWindow")
    public static let axCreateWithRemoteToken: AXCreateWithRemoteToken? = resolve("_AXUIElementCreateWithRemoteToken")
    public static let mainConnectionID: MainConnectionID? = resolve("CGSMainConnectionID")
    public static let hwCaptureWindowList: HWCaptureWindowList? = resolve("CGSHWCaptureWindowList")
    public static let setFrontProcessWithOptions: SetFrontProcessWithOptions? = resolve("_SLPSSetFrontProcessWithOptions")
    public static let postEventRecordTo: PostEventRecordTo? = resolve("SLPSPostEventRecordTo")
    public static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? = resolve("SLSCopyManagedDisplaySpaces")
    public static let copySpacesForWindows: CopySpacesForWindows? = resolve("SLSCopySpacesForWindows")
    public static let getActiveSpace: GetActiveSpace? = resolve("SLSGetActiveSpace")
    public static let getProcessForPID: GetProcessForPID? = resolve("GetProcessForPID")

    /// Names of the symbols this macOS does not provide (shown in diagnostics).
    public static var missing: [String] {
        var names: [String] = []
        if axGetWindow == nil { names.append("_AXUIElementGetWindow") }
        if axCreateWithRemoteToken == nil { names.append("_AXUIElementCreateWithRemoteToken") }
        if mainConnectionID == nil { names.append("CGSMainConnectionID") }
        if hwCaptureWindowList == nil { names.append("CGSHWCaptureWindowList") }
        if setFrontProcessWithOptions == nil { names.append("_SLPSSetFrontProcessWithOptions") }
        if postEventRecordTo == nil { names.append("SLPSPostEventRecordTo") }
        if copyManagedDisplaySpaces == nil { names.append("SLSCopyManagedDisplaySpaces") }
        if copySpacesForWindows == nil { names.append("SLSCopySpacesForWindows") }
        if getActiveSpace == nil { names.append("SLSGetActiveSpace") }
        if getProcessForPID == nil { names.append("GetProcessForPID") }
        return names
    }
}
