#import <Foundation/Foundation.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <ifaddrs.h>
#import <net/if_dl.h>
#import <string.h>
#import <stdlib.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

static CFArrayRef (*orig_CNCopySupportedInterfaces)(void);
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef);
static int (*orig_getifaddrs)(struct ifaddrs **);

static BOOL NDParseMAC(NSString *mac, uint8_t out[6]) {
    if (mac.length < 11 || !out) return NO;
    unsigned int b[6] = {0};
    if (sscanf(mac.UTF8String, "%x:%x:%x:%x:%x:%x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) return NO;
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)b[i];
    return YES;
}

static void NDPatchLinkMAC(struct ifaddrs *ifa, NSString *mac) {
    if (!ifa || !ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_LINK || !mac.length) return;
    struct sockaddr_dl *sdl = (struct sockaddr_dl *)ifa->ifa_addr;
    if (sdl->sdl_alen < 6) return;
    uint8_t bytes[6];
    if (!NDParseMAC(mac, bytes)) return;
    memcpy(LLADDR(sdl), bytes, 6);
}

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

static int hooked_getifaddrs(struct ifaddrs **ifap) {
    int rc = orig_getifaddrs ? orig_getifaddrs(ifap) : -1;
    if (rc != 0 || !ifap || !*ifap) return rc;
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof]) return rc;
    NSString *wifi = st.profile.WiFiMAC;
    NSString *bt = st.profile.BTMAC;
    if (!wifi.length && !bt.length) return rc;
    for (struct ifaddrs *ifa = *ifap; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name) continue;
        if (wifi.length && (strcmp(ifa->ifa_name, "en0") == 0 || strcmp(ifa->ifa_name, "en1") == 0)) {
            NDPatchLinkMAC(ifa, wifi);
        } else if (bt.length && strncmp(ifa->ifa_name, "anpi", 4) == 0) {
            NDPatchLinkMAC(ifa, bt);
        }
    }
    return rc;
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
    void *symGetIf = dlsym(RTLD_DEFAULT, "getifaddrs");
    if (symGetIf) {
        MSHookFunction(symGetIf, (void *)hooked_getifaddrs, (void **)&orig_getifaddrs);
    }
}
