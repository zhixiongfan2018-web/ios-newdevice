#import <Foundation/Foundation.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <ifaddrs.h>
#import <net/if_dl.h>
#import <arpa/inet.h>
#import <string.h>
#import <stdlib.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"
#import "NDIfaddrsFingerprint.h"
#import "NDRuntimeState.h"

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

static NSDictionary *NDCurrentIfaddrsMap(void) {
    NSDictionary *runtime = [NDRuntimeState dictionary];
    id map = runtime[@"ifaddrs"];
    if ([map isKindOfClass:[NSDictionary class]] && [(NSDictionary *)map count]) return map;
    NDTweakState *st = [NDTweakState shared];
    NSString *name = st.profile.name;
    NSDictionary *fromDisk = [NDIfaddrsFingerprint loadForRecord:name];
    if (fromDisk.count) return fromDisk;
    return nil;
}

static void NDApplyIfaceFingerprint(struct ifaddrs *ifa, NSDictionary *iface) {
    if (!ifa || ![iface isKindOfClass:[NSDictionary class]]) return;
    NSString *mac = iface[@"mac"];
    if ([mac isKindOfClass:[NSString class]] && mac.length) {
        NDPatchLinkMAC(ifa, mac);
    }
    NSString *ipv4 = iface[@"ipv4"];
    NSString *mask = iface[@"submask"] ?: @"255.255.255.0";
    NSString *ipv6 = iface[@"ipv6"];
    NSString *dst = iface[@"dst"];
    if (ifa->ifa_addr) {
        if (ifa->ifa_addr->sa_family == AF_INET && [ipv4 isKindOfClass:[NSString class]]) {
            [NDIfaddrsFingerprint applyIPv4:ipv4 mask:mask toSockaddr:ifa->ifa_addr netmask:ifa->ifa_netmask];
        } else if (ifa->ifa_addr->sa_family == AF_INET6 && [ipv6 isKindOfClass:[NSString class]]) {
            [NDIfaddrsFingerprint applyIPv6:ipv6 toSockaddr:ifa->ifa_addr];
        }
    }
    if (ifa->ifa_dstaddr && [dst isKindOfClass:[NSString class]] && dst.length) {
        if (ifa->ifa_dstaddr->sa_family == AF_INET) {
            [NDIfaddrsFingerprint applyIPv4:dst toDstaddr:ifa->ifa_dstaddr];
        }
    }
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

    NSDictionary *map = NDCurrentIfaddrsMap();
    NSString *wifi = st.profile.WiFiMAC;
    NSString *bt = st.profile.BTMAC;

    for (struct ifaddrs *ifa = *ifap; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name) continue;
        NSString *iname = @(ifa->ifa_name);
        NSDictionary *iface = map[iname];
        if ([iface isKindOfClass:[NSDictionary class]]) {
            NDApplyIfaceFingerprint(ifa, iface);
            continue;
        }
        // Fallback: MAC-only when no ifaddrs.plist entry
        if (wifi.length && ([iname isEqualToString:@"en0"] || [iname isEqualToString:@"en1"])) {
            NDPatchLinkMAC(ifa, wifi);
        } else if (bt.length && [iname hasPrefix:@"anpi"]) {
            NDPatchLinkMAC(ifa, bt);
        }
    }
    return rc;
}

%group NDNetworkInfo
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
%end // NDNetworkInfo

%ctor {
    NDRunAfterUIKitReady(^{
        [[NDTweakState shared] reload];
        if (NDIsPrizePicksHost() && ![[NDTweakState shared] shouldSpoof]) return;
        %init(NDNetworkInfo);
        if (NDIsSystemIdentityHost() || NDIsPrizePicksHost()) return;
        void *symIf = dlsym(RTLD_DEFAULT, "CNCopySupportedInterfaces");
        void *symInfo = dlsym(RTLD_DEFAULT, "CNCopyCurrentNetworkInfo");
        if (symIf) {
            MSHookFunction(symIf, (void *)hooked_CNCopySupportedInterfaces, (void **)&orig_CNCopySupportedInterfaces);
        }
        if (symInfo) {
            MSHookFunction(symInfo, (void *)hooked_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);
        }
    });
    NDRunRiskyCHooksAfterUIKitReady(^{
        void *symIf = dlsym(RTLD_DEFAULT, "CNCopySupportedInterfaces");
        void *symInfo = dlsym(RTLD_DEFAULT, "CNCopyCurrentNetworkInfo");
        if (symIf && !orig_CNCopySupportedInterfaces) {
            MSHookFunction(symIf, (void *)hooked_CNCopySupportedInterfaces, (void **)&orig_CNCopySupportedInterfaces);
        }
        if (symInfo && !orig_CNCopyCurrentNetworkInfo) {
            MSHookFunction(symInfo, (void *)hooked_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo);
        }
        void *symGetIf = dlsym(RTLD_DEFAULT, "getifaddrs");
        if (symGetIf) {
            MSHookFunction(symGetIf, (void *)hooked_getifaddrs, (void **)&orig_getifaddrs);
        }
    });
}
