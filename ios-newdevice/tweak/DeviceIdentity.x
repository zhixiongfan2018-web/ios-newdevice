#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <dlfcn.h>
#import <substrate.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

static NSUUID *NDUUIDFromString(NSString *s) {
    if (!s.length) return nil;
    return [[NSUUID alloc] initWithUUIDString:s];
}

%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.IDFA.length) {
        NSUUID *u = NDUUIDFromString(st.profile.IDFA);
        if (u) return u;
    }
    return %orig;
}
%end

%hook UIDevice
- (NSUUID *)identifierForVendor {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.IDFV.length) {
        NSUUID *u = NDUUIDFromString(st.profile.IDFV);
        if (u) return u;
    }
    return %orig;
}

- (NSString *)name {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeDeviceModel && st.profile.Model.length) {
        return st.profile.Model;
    }
    return %orig;
}
%end

typedef CFTypeRef (*MGCopyAnswerFunc)(CFStringRef);

static CFTypeRef (*orig_MGCopyAnswer)(CFStringRef);
static CFTypeRef hooked_MGCopyAnswer(CFStringRef key) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && key) {
        NSString *k = (__bridge NSString *)key;
        NDDeviceProfile *p = st.profile;
        NSDictionary *map = @{
            @"SerialNumber": p.Serial ?: @"",
            @"UniqueDeviceID": p.UDID ?: @"",
            @"UniqueDeviceIDData": p.UDID ?: @"",
            @"WifiAddress": p.WiFiMAC ?: @"",
            @"BluetoothAddress": p.BTMAC ?: @"",
            @"ProductType": st.config.fakeDeviceModel ? (p.ProductType ?: @"") : @"",
            @"HardwareModel": st.config.fakeDeviceModel ? (p.HardwareMachine ?: @"") : @"",
            @"DeviceName": st.config.fakeDeviceModel ? (p.Model ?: @"") : @"",
            @"ProductVersion": st.config.fakeSystemVer ? (p.SystemVer ?: @"") : @"",
            @"BuildVersion": st.config.fakeSystemVer ? (p.Build ?: @"") : @"",
        };
        NSString *val = map[k];
        if (val.length) {
            return CFBridgingRetain(val);
        }
    }
    return orig_MGCopyAnswer ? orig_MGCopyAnswer(key) : NULL;
}

%ctor {
    if (!NDShouldLoadTweak()) return;
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (!gestalt) gestalt = dlopen("/var/jb/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (gestalt) {
        void *sym = dlsym(gestalt, "MGCopyAnswer");
        if (sym) {
            MSHookFunction(sym, (void *)hooked_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
        }
    }
}
