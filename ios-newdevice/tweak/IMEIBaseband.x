#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <substrate.h>
#import <CoreFoundation/CoreFoundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

/// Baseband-adjacent IMEI surfaces: IOKit registry strings + private telephony helpers.
/// True modem NVRAM rewrite is not available on modern rootless; this covers the paths
/// apps / CommCenter commonly read after Gestalt.

static BOOL NDKeyLooksLikeEquipment(NSString *key) {
    if (!key.length) return NO;
    NSString *l = key.lowercaseString;
    return [l containsString:@"imei"]
        || [l containsString:@"meid"]
        || [l containsString:@"mobileequipment"]
        || [l containsString:@"inversedevice"]
        || [l isEqualToString:@"deviceid"]
        || [l containsString:@"internationalequipment"];
}

static NSString *NDSpoofedIMEIForKey(NSString *key) {
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoofIdentity]) return nil;
    NDDeviceProfile *p = st.profile;
    NSString *l = key.lowercaseString;
    if ([l containsString:@"imei2"] || [l containsString:@"identity2"]) {
        return p.IMEI2.length ? p.IMEI2 : p.IMEI;
    }
    if (p.IMEI.length) return p.IMEI;
    return p.IMEI2;
}

typedef CFTypeRef (*IORegCopyFunc)(uint32_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options);
static IORegCopyFunc orig_IORegistryEntryCreateCFProperty;
static CFTypeRef hooked_IORegistryEntryCreateCFProperty(uint32_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) {
    if (key) {
        NSString *ks = (__bridge NSString *)key;
        if (NDKeyLooksLikeEquipment(ks)) {
            NSString *spoof = NDSpoofedIMEIForKey(ks);
            if (spoof.length) return CFBridgingRetain(spoof);
        }
    }
    return orig_IORegistryEntryCreateCFProperty ? orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options) : NULL;
}

typedef CFTypeRef (*IORegSearchFunc)(uint32_t entry, const char *plane, CFStringRef key, CFAllocatorRef allocator, uint32_t options);
static IORegSearchFunc orig_IORegistryEntrySearchCFProperty;
static CFTypeRef hooked_IORegistryEntrySearchCFProperty(uint32_t entry, const char *plane, CFStringRef key, CFAllocatorRef allocator, uint32_t options) {
    if (key) {
        NSString *ks = (__bridge NSString *)key;
        if (NDKeyLooksLikeEquipment(ks)) {
            NSString *spoof = NDSpoofedIMEIForKey(ks);
            if (spoof.length) return CFBridgingRetain(spoof);
        }
    }
    return orig_IORegistryEntrySearchCFProperty ? orig_IORegistryEntrySearchCFProperty(entry, plane, key, allocator, options) : NULL;
}

static CFDictionaryRef (*orig_CTServerConnectionCopyMobileEquipmentInfo)(void *);
static CFDictionaryRef hooked_CTServerConnectionCopyMobileEquipmentInfo(void *connection) {
    CFDictionaryRef orig = orig_CTServerConnectionCopyMobileEquipmentInfo ? orig_CTServerConnectionCopyMobileEquipmentInfo(connection) : NULL;
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoofIdentity] || !st.profile.IMEI.length) return orig;
    NSMutableDictionary *out = orig ? [(__bridge NSDictionary *)orig mutableCopy] : [NSMutableDictionary dictionary];
    out[@"kCTMobileEquipmentInfoIMEI"] = st.profile.IMEI;
    out[@"kCTMobileEquipmentInfoCurrentMobileId"] = st.profile.IMEI;
    out[@"IMEI"] = st.profile.IMEI;
    if (st.profile.IMEI2.length) {
        out[@"kCTMobileEquipmentInfoIMEI2"] = st.profile.IMEI2;
        out[@"IMEI2"] = st.profile.IMEI2;
    }
    if (orig) CFRelease(orig);
    return CFBridgingRetain(out);
}

%group NDIMEIBaseband
%hook NSDictionary
- (id)objectForKey:(id)aKey {
    id v = %orig;
    if (![aKey isKindOfClass:[NSString class]]) return v;
    if (!NDKeyLooksLikeEquipment((NSString *)aKey)) return v;
    NDTweakState *st = [NDTweakState shared];
    // Only rewrite in identity hosts to avoid broad NSDictionary overhead in every app
    if (!st.identityHost || ![st shouldSpoofIdentity]) return v;
    NSString *spoof = NDSpoofedIMEIForKey((NSString *)aKey);
    return spoof.length ? spoof : v;
}
%end
%end // NDIMEIBaseband

%ctor {
    NDRunAfterUIKitReady(^{
        %init(NDIMEIBaseband);
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!iokit) iokit = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_NOW);
        if (iokit) {
        void *p1 = dlsym(iokit, "IORegistryEntryCreateCFProperty");
        if (p1) MSHookFunction(p1, (void *)hooked_IORegistryEntryCreateCFProperty, (void **)&orig_IORegistryEntryCreateCFProperty);
        void *p2 = dlsym(iokit, "IORegistryEntrySearchCFProperty");
        if (p2) MSHookFunction(p2, (void *)hooked_IORegistryEntrySearchCFProperty, (void **)&orig_IORegistryEntrySearchCFProperty);
        }
        void *ct = dlsym(RTLD_DEFAULT, "CTServerConnectionCopyMobileEquipmentInfo");
        if (ct) {
        MSHookFunction(ct, (void *)hooked_CTServerConnectionCopyMobileEquipmentInfo, (void **)&orig_CTServerConnectionCopyMobileEquipmentInfo);
        }
    });
}
