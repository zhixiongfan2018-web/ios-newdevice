#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <dlfcn.h>
#import <substrate.h>
#import "NDTweakState.h"

static NSUUID *NDUUIDFromString(NSString *s) {
    if (!s.length) return nil;
    return [[NSUUID alloc] initWithUUIDString:s];
}

static NSData *NDDataFromHexString(NSString *hex) {
    if (!hex.length) return nil;
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
    if (clean.length % 2 != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:clean.length / 2];
    const char *c = clean.UTF8String;
    for (NSUInteger i = 0; i + 1 < clean.length; i += 2) {
        unsigned int byte = 0;
        if (sscanf(c + i, "%2x", &byte) != 1) return nil;
        uint8_t b = (uint8_t)byte;
        [data appendBytes:&b length:1];
    }
    return data;
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

        // UniqueDeviceIDData is CFData(20 bytes) on real devices — hex-decode UDID.
        if ([k isEqualToString:@"UniqueDeviceIDData"] && p.UDID.length) {
            NSData *data = NDDataFromHexString(p.UDID);
            if (data) return CFBridgingRetain(data);
        }

        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        if (p.Serial.length) map[@"SerialNumber"] = p.Serial;
        if (p.UDID.length) map[@"UniqueDeviceID"] = p.UDID;
        if (p.WiFiMAC.length) map[@"WifiAddress"] = p.WiFiMAC;
        if (p.BTMAC.length) map[@"BluetoothAddress"] = p.BTMAC;
        if (st.config.fakeDeviceModel) {
            if (p.ProductType.length) map[@"ProductType"] = p.ProductType;
            // Board id — do NOT reuse ProductType here (was a common "没生效"/crash cause).
            if (p.HardwareModel.length) map[@"HardwareModel"] = p.HardwareModel;
            if (p.Model.length) map[@"DeviceName"] = p.Model;
        }
        if (st.config.fakeSystemVer) {
            if (p.SystemVer.length) map[@"ProductVersion"] = p.SystemVer;
            if (p.Build.length) map[@"BuildVersion"] = p.Build;
        }
        NSString *val = map[k];
        if (val.length) {
            return CFBridgingRetain(val);
        }
    }
    return orig_MGCopyAnswer ? orig_MGCopyAnswer(key) : NULL;
}

%ctor {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (!gestalt) gestalt = dlopen("/var/jb/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (gestalt) {
        void *sym = dlsym(gestalt, "MGCopyAnswer");
        if (sym) {
            MSHookFunction(sym, (void *)hooked_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
        }
    }
}
