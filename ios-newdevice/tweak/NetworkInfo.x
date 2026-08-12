#import <Foundation/Foundation.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

static CFArrayRef (*orig_CNCopySupportedInterfaces)(void);
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef);

static CFArrayRef hooked_CNCopySupportedInterfaces(void) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.SSID.length) {
        NSArray *arr = @[@"en0"];
        return CFBridgingRetain(arr);
    }
    return orig_CNCopySupportedInterfaces ? orig_CNCopySupportedInterfaces() : NULL;
}

static CFDictionaryRef hooked_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.SSID.length) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[(__bridge NSString *)kCNNetworkInfoKeySSID] = st.profile.SSID;
        if (st.profile.BSSID.length) {
            info[(__bridge NSString *)kCNNetworkInfoKeyBSSID] = st.profile.BSSID;
        }
        NSData *ssidData = [st.profile.SSID dataUsingEncoding:NSUTF8StringEncoding];
        if (ssidData) info[(__bridge NSString *)kCNNetworkInfoKeySSIDData] = ssidData;
        return CFBridgingRetain(info);
    }
    return orig_CNCopyCurrentNetworkInfo ? orig_CNCopyCurrentNetworkInfo(interfaceName) : NULL;
}

%hook NEHotspotNetwork
- (NSString *)SSID {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.SSID.length) return st.profile.SSID;
    return %orig;
}
- (NSString *)BSSID {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.BSSID.length) return st.profile.BSSID;
    return %orig;
}
%end

%ctor {
    if (!NDShouldLoadTweak()) return;
    void *symIf = dlsym(RTLD_DEFAULT, "CNCopySupportedInterfaces");
    void *symInfo = dlsym(RTLD_DEFAULT, "CNCopyCurrentNetworkInfo");
    if (symIf) {
        MSHookFunction(symIf, (void *)hooked_CNCopySupportedInterfaces, (void **)&orig_CNCopySupportedInterfaces);
    }
    if (symInfo) {
        MSHookFunction(symInfo, (void *)hooked_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);
    }
}
