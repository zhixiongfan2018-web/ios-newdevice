#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <dlfcn.h>
#import <substrate.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"
#import "NDDeviceCatalog+Metrics.h"

static NSUUID *NDUUIDFromString(NSString *s) {
    if (!s.length) return nil;
    return [[NSUUID alloc] initWithUUIDString:s];
}

/// Decode 40-char hex UDID into 20 raw bytes (MobileGestalt UniqueDeviceIDData format).
static NSData *NDHexDataFromUDID(NSString *udid) {
    if (udid.length != 40) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:20];
    uint8_t *bytes = data.mutableBytes;
    const char *c = udid.UTF8String;
    for (NSUInteger i = 0; i < 20; i++) {
        unsigned int byte = 0;
        if (sscanf(c + i * 2, "%2x", &byte) != 1) return nil;
        bytes[i] = (uint8_t)byte;
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
- (BOOL)isAdvertisingTrackingEnabled {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof]) {
        return st.profile.AdvertisingTrackingEnabled;
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
    if ([st shouldSpoof] && st.config.fakeDeviceModel) {
        if (st.profile.DeviceName.length) return st.profile.DeviceName;
        if (st.profile.Model.length) return st.profile.Model;
    }
    return %orig;
}
%end

typedef CFTypeRef (*MGCopyAnswerFunc)(CFStringRef);

static CFTypeRef (*orig_MGCopyAnswer)(CFStringRef);
static CFTypeRef hooked_MGCopyAnswer(CFStringRef key) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoofIdentity] && key) {
        NSString *k = (__bridge NSString *)key;
        NDDeviceProfile *p = st.profile;

        if ([k isEqualToString:@"UniqueDeviceIDData"] && p.UDID.length) {
            NSData *data = NDHexDataFromUDID(p.UDID);
            if (data) return CFBridgingRetain(data);
            return CFBridgingRetain([p.UDID dataUsingEncoding:NSUTF8StringEncoding]);
        }

        // In CommCenter (identity host), still apply equipment / model gestalt
        BOOL modelGate = st.config.fakeDeviceModel || st.identityHost;
        if (modelGate) {
            if ([k isEqualToString:@"PhysicalMemory"]) {
                uint64_t mem = p.PhysicalMemory > 0 ? p.PhysicalMemory : [NDDeviceCatalog memoryBytesForProductType:p.ProductType];
                if (mem > 0) return CFBridgingRetain(@(mem));
            }
            if (([k isEqualToString:@"TotalDiskCapacity"] || [k isEqualToString:@"DiskCapacity"]) && p.DiskCapacity > 0) {
                return CFBridgingRetain(@(p.DiskCapacity));
            }
            if ([k isEqualToString:@"DeviceClassNumber"]) {
                BOOL isPad = [p.ProductType hasPrefix:@"iPad"];
                return CFBridgingRetain(@(isPad ? 2 : 1));
            }
        }

        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        if (p.Serial.length) map[@"SerialNumber"] = p.Serial;
        if (p.UDID.length) map[@"UniqueDeviceID"] = p.UDID;
        if (p.WiFiMAC.length) map[@"WifiAddress"] = p.WiFiMAC;
        if (p.BTMAC.length) map[@"BluetoothAddress"] = p.BTMAC;
        if (p.IMEI.length) {
            map[@"InternationalMobileEquipmentIdentity"] = p.IMEI;
            map[@"InternationalMobileEquipmentIdentity1"] = p.IMEI;
            map[@"InverseDeviceID"] = p.IMEI;
            map[@"DeviceId"] = p.IMEI;
            // MEID-ish hex form some baseband stacks expose (14 hex from first 14 decimal digits)
            if (p.IMEI.length >= 14) {
                map[@"MobileEquipmentIdentifier"] = p.IMEI;
            }
        }
        if (p.IMEI2.length) {
            map[@"InternationalMobileEquipmentIdentity2"] = p.IMEI2;
        }
        if (p.OpenUDID.length) map[@"OpenUDID"] = p.OpenUDID;

        if (modelGate) {
            if (p.ProductType.length) {
                map[@"ProductType"] = p.ProductType;
                map[@"HardwarePlatform"] = p.ProductType;
                map[@"CompatibleProductType"] = p.ProductType;
            }
            if (p.HardwareMachine.length) {
                map[@"HardwareModel"] = p.HardwareMachine;
                map[@"HWModelStr"] = p.HardwareMachine;
            }
            if (p.Model.length) {
                map[@"MarketingProductName"] = p.Model;
            }
            NSString *deviceName = p.DeviceName.length ? p.DeviceName : p.Model;
            if (deviceName.length) {
                map[@"DeviceName"] = deviceName;
                map[@"UserAssignedDeviceName"] = deviceName;
            }
            BOOL isPad = [p.ProductType hasPrefix:@"iPad"];
            map[@"DeviceClass"] = isPad ? @"iPad" : @"iPhone";
            if (p.DeviceColor.length) {
                map[@"DeviceColor"] = p.DeviceColor;
                map[@"DeviceEnclosureColor"] = p.DeviceColor;
            }
        }
        if (st.config.fakeSystemVer || st.identityHost) {
            if (p.SystemVer.length) map[@"ProductVersion"] = p.SystemVer;
            if (p.Build.length) map[@"BuildVersion"] = p.Build;
        }
        // US locale identity hints (when spoofing carrier / device)
        if (st.config.fakeCarrier || st.identityHost) {
            map[@"RegionInfo"] = @"US";
            map[@"RegionCode"] = @"US";
        }

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
