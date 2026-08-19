#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <dlfcn.h>
#import <stdint.h>
#import <string.h>
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

/// Delayed IDFA/IDFV + device name. Model/systemVersion come from ModelVersion ObjC.
/// MG whitelist is installed after UIKit — serial/UDID/IMEI/WiFi for in-app reads.
%group NDDeviceIdentityVenmo
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
    if ([st shouldSpoof] && st.profile.DeviceName.length) return st.profile.DeviceName;
    if ([st shouldSpoof] && st.profile.Model.length) return st.profile.Model;
    return %orig;
}
%end
%end // NDDeviceIdentityVenmo

%group NDDeviceIdentity
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
    if ([st shouldSpoof] && (st.config.fakeDeviceModel || NDIsPrizePicksHost())) {
        if (st.profile.DeviceName.length) return st.profile.DeviceName;
        if (st.profile.Model.length) return st.profile.Model;
    }
    return %orig;
}
%end
%end // NDDeviceIdentity

typedef CFTypeRef (*MGCopyAnswerFunc)(CFStringRef);

static BOOL NDVenmoMGKeyAllowed(NSString *k) {
    // Minimal AMG-like faker surface inside Venmo — avoid binary / screen / baseband edge keys.
    static NSSet *allow;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allow = [NSSet setWithArray:@[
            @"ProductType", @"CompatibleProductType",
            @"SerialNumber", @"UniqueDeviceID",
            @"WifiAddress", @"BluetoothAddress",
            @"ProductVersion", @"BuildVersion",
            @"HardwareModel", @"HWModelStr",
            @"MarketingProductName", @"DeviceName", @"UserAssignedDeviceName",
            @"DeviceClass", @"RegionInfo", @"RegionCode",
            @"InternationalMobileEquipmentIdentity",
            @"InternationalMobileEquipmentIdentity1",
            @"InternationalMobileEquipmentIdentity2",
        ]];
    });
    return k.length && [allow containsObject:k];
}

static CFTypeRef (*orig_MGCopyAnswer)(CFStringRef);

static CFTypeRef NDOrigMGCopyAnswer(CFStringRef key, uint32_t *outTypeCode) {
    (void)outTypeCode;
    if (orig_MGCopyAnswer) return orig_MGCopyAnswer(key);
    return NULL;
}

static BOOL NDFramePathContains(void *addr, const char *needle) {
    if (!addr || !needle) return NO;
    Dl_info inf;
    memset(&inf, 0, sizeof(inf));
    if (!dladdr(addr, &inf) || !inf.dli_fname) return NO;
    return strstr(inf.dli_fname, needle) != NULL;
}

/// CoreUI reads gestalt for display traits. Spoofing those keys (or the call itself)
/// SIGILL'd PrizePicks. Pass the real answer when the caller is CoreUI.
static BOOL NDCallerIsCoreUI(void) {
    if (NDFramePathContains(__builtin_return_address(0), "CoreUI")) return YES;
    if (NDFramePathContains(__builtin_return_address(1), "CoreUI")) return YES;
    return NO;
}

static CFTypeRef hooked_MGCopyAnswer(CFStringRef key) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoofIdentity] && key) {
        NSString *k = (__bridge NSString *)key;
        if (NDIsPrizePicksHost() && NDCallerIsCoreUI()) {
            return NDOrigMGCopyAnswer(key, NULL);
        }
        // Venmo / PrizePicks: only remap a small string whitelist (full MG hook historically SIGSEGV'd).
        if ((NDIsVenmoHost() || NDIsPrizePicksHost()) && !NDVenmoMGKeyAllowed(k)) {
            return NDOrigMGCopyAnswer(key, NULL);
        }
        NDDeviceProfile *p = st.profile;

        if ([k isEqualToString:@"UniqueDeviceIDData"] && p.UDID.length) {
            NSData *data = NDHexDataFromUDID(p.UDID);
            if (data) return CFBridgingRetain(data);
            return CFBridgingRetain([p.UDID dataUsingEncoding:NSUTF8StringEncoding]);
        }

        // In CommCenter (identity host), still apply equipment / model gestalt
        BOOL modelGate = st.config.fakeDeviceModel || st.identityHost || NDIsPrizePicksHost();
        if (modelGate) {
            if ([k isEqualToString:@"PhysicalMemory"]) {
                uint64_t mem = p.PhysicalMemory > 0 ? p.PhysicalMemory : [NDDeviceCatalog memoryBytesForProductType:p.ProductType];
                if (mem > 0) return CFBridgingRetain(@(mem));
            }
            if ([k isEqualToString:@"TotalDiskCapacity"] || [k isEqualToString:@"DiskCapacity"]) {
                uint64_t disk = p.DiskCapacity > 0 ? p.DiskCapacity : [NDDeviceCatalog diskBytesForProductType:p.ProductType];
                if (disk > 0) return CFBridgingRetain(@(disk));
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
                map[@"CompatibleProductType"] = p.ProductType;
            }
            // HardwareModel / HWModelStr are board ids (D79AP), NOT ProductType (iPhone12,8).
            NSString *board = [NDDeviceCatalog boardIdForProductType:p.ProductType];
            if (board.length) {
                map[@"HardwareModel"] = board;
                map[@"HWModelStr"] = board;
            }
            if (p.Model.length) {
                map[@"MarketingProductName"] = p.Model;
            }
            NSString *deviceName = p.DeviceName.length ? p.DeviceName : p.Model;
            if (deviceName.length && ![[deviceName lowercaseString] hasPrefix:@"iphone1"] && ![deviceName containsString:@","]) {
                map[@"DeviceName"] = deviceName;
                map[@"UserAssignedDeviceName"] = deviceName;
            } else if (p.Model.length && ![p.Model containsString:@","]) {
                map[@"DeviceName"] = p.Model;
                map[@"UserAssignedDeviceName"] = p.Model;
            }
            BOOL isPad = [p.ProductType hasPrefix:@"iPad"];
            map[@"DeviceClass"] = isPad ? @"iPad" : @"iPhone";
            if (p.DeviceColor.length) {
                map[@"DeviceColor"] = p.DeviceColor;
                map[@"DeviceEnclosureColor"] = p.DeviceColor;
            }
            NSDictionary *metrics = [NDDeviceCatalog displayMetricsForProductType:p.ProductType];
            if (metrics) {
                double w = [metrics[@"w"] doubleValue];
                double h = [metrics[@"h"] doubleValue];
                double scale = [metrics[@"scale"] doubleValue];
                if ([k isEqualToString:@"main-screen-width"] || [k isEqualToString:@"MainScreenWidth"]) {
                    return CFBridgingRetain(@(w * scale));
                }
                if ([k isEqualToString:@"main-screen-height"] || [k isEqualToString:@"MainScreenHeight"]) {
                    return CFBridgingRetain(@(h * scale));
                }
                if ([k isEqualToString:@"main-screen-scale"] || [k isEqualToString:@"MainScreenScale"] || [k isEqualToString:@"MainScreenPitch"]) {
                    return CFBridgingRetain(@(scale));
                }
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
        if (p.WiFiMAC.length) {
            map[@"EthernetMacAddress"] = p.WiFiMAC;
        }
        if (p.Serial.length) {
            map[@"MLBSerialNumber"] = p.Serial;
            map[@"BasebandSerialNumber"] = p.Serial;
        }
        if (p.UDID.length >= 16) {
            map[@"UniqueChipID"] = [p.UDID substringToIndex:16];
            map[@"ArcPrimaryDeviceUUID"] = p.UDID;
        }
        if (p.UUID.length) {
            map[@"UserAssignedUniqueID"] = p.UUID;
        }
        if (p.OpenUDID.length) {
            map[@"OpenUDID"] = p.OpenUDID;
        }
        if (p.ICCID.length) {
            map[@"IntegratedCircuitCardIdentifier"] = p.ICCID;
            map[@"ICCID"] = p.ICCID;
        }
        // Do NOT set ModelNumber/RegulatoryModelNumber to ProductType — those are
        // regulatory SKUs (e.g. MHGP3), not machine ids (iPhone12,8).

        NSString *val = map[k];
        if (val.length) {
            return CFBridgingRetain(val);
        }
    }
    return NDOrigMGCopyAnswer(key, NULL);
}

typedef CFTypeRef (*MGCopyAnswerErrFunc)(CFStringRef, void *);
static MGCopyAnswerErrFunc orig_MGCopyAnswerWithError;
static CFTypeRef hooked_MGCopyAnswerWithError(CFStringRef key, void *errOut) {
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoofIdentity]) {
        return orig_MGCopyAnswerWithError ? orig_MGCopyAnswerWithError(key, errOut)
                                          : (orig_MGCopyAnswer ? orig_MGCopyAnswer(key) : NULL);
    }
    CFTypeRef v = hooked_MGCopyAnswer(key);
    if (errOut) *((CFErrorRef *)errOut) = NULL;
    return v;
}

%ctor {
    void (^writeIdentityMarker)(BOOL amgOwns, BOOL mgHook) = ^(BOOL amgOwns, BOOL mgHook) {
        @try {
            NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
            if (!bid.length || [bid hasPrefix:@"com.apple."]) return;
            NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
            [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
            NDDeviceProfile *p = [NDTweakState shared].profile;
            NSString *line = [NSString stringWithFormat:
                              @"bid=%@\nidfa=%@\nproduct=%@\nsys=%@\nserial=%@\nudid=%@\nimei=%@\namgOwns=%@\nmgHook=%@\ntime=%@\n",
                              bid,
                              p.IDFA ?: @"",
                              p.ProductType ?: @"",
                              p.SystemVer ?: @"",
                              p.Serial ?: @"",
                              p.UDID ?: @"",
                              p.IMEI ?: @"",
                              amgOwns ? @"1" : @"0",
                              mgHook ? @"1" : @"0",
                              [NSDate date]];
            [line writeToFile:[docs stringByAppendingPathComponent:@"nd-identity-ok.txt"]
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (__unused NSException *ex) {
        }
    };

    void (^installGestalt)(void) = ^{
        void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (!gestalt) gestalt = dlopen("/var/jb/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (!gestalt) return;
        void *sym = dlsym(gestalt, "MGCopyAnswer");
        if (sym) {
            MSHookFunction(sym, (void *)hooked_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
        }
        void *symErr = dlsym(gestalt, "MGCopyAnswerWithError");
        if (symErr) {
            MSHookFunction(symErr, (void *)hooked_MGCopyAnswerWithError, (void **)&orig_MGCopyAnswerWithError);
        }
    };

    // Venmo: delayed IDFA/name + MG whitelist (serial/UDID/IMEI/WiFi). No sysctl.
    if (NDIsVenmoHost()) {
        NDRunVenmoSafeObjCHooksAfterReady(^{
            @try {
                [[NDTweakState shared] reload];
                if (![[NDTweakState shared] shouldSpoof] && ![[NDTweakState shared] shouldSpoofIdentity]) return;
                BOOL amgOwns = NDAmgDylibLoaded();
                if (!amgOwns) {
                    %init(NDDeviceIdentityVenmo);
                    installGestalt();
                }
                writeIdentityMarker(amgOwns, !amgOwns);
            } @catch (__unused NSException *ex) {
            }
        });
        return;
    }

    NDRunAfterUIKitReady(^{
        [[NDTweakState shared] reload];
        if (![[NDTweakState shared] shouldSpoof] && ![[NDTweakState shared] shouldSpoofIdentity]) return;

        %init(NDDeviceIdentity);

        // PrizePicks: IDFA/name + MG whitelist (CoreUI passthrough). No sysctl/UIScreen.
        if (NDIsPrizePicksHost()) {
            BOOL amgOwns = NDAmgDylibLoaded();
            if (!amgOwns) installGestalt();
            writeIdentityMarker(amgOwns, !amgOwns);
            return;
        }

        installGestalt();
        writeIdentityMarker(NDAmgDylibLoaded(), YES);
    });
}
