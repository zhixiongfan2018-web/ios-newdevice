#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <dlfcn.h>
#import <substrate.h>
#import <resolv.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <string.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"
#import "NDRuntimeState.h"
#import "NDIfaddrsFingerprint.h"

static NSArray<NSString *> *NDSpoofDNSServers(void) {
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof]) return nil;
    NSDictionary *runtime = [NDRuntimeState dictionary];
    id dns = runtime[@"ifaddrs"][@"dns"];
    if (![dns isKindOfClass:[NSArray class]] || ![dns count]) {
        NSDictionary *disk = [NDIfaddrsFingerprint loadForRecord:st.profile.name];
        dns = disk[@"dns"];
    }
    if (![dns isKindOfClass:[NSArray class]] || ![dns count]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id item in (NSArray *)dns) {
        if ([item isKindOfClass:[NSString class]] && [item length]) [out addObject:item];
    }
    return out.count ? out : nil;
}

static CFDictionaryRef NDMakeDNSDict(NSArray<NSString *> *servers, CFDictionaryRef base) {
    NSMutableDictionary *dict = base ? [(__bridge NSDictionary *)base mutableCopy] : [NSMutableDictionary dictionary];
    dict[@"ServerAddresses"] = servers;
    // Common alternate keys apps/libraries sniff
    dict[@"SupplementalMatchDomains"] = dict[@"SupplementalMatchDomains"] ?: @[];
    return CFBridgingRetain(dict);
}

static BOOL NDKeyIsDNSPath(CFStringRef key) {
    if (!key) return NO;
    NSString *s = (__bridge NSString *)key;
    if ([s containsString:@"/DNS"]) return YES;
    if ([s isEqualToString:@"State:/Network/Global/DNS"]) return YES;
    return NO;
}

static CFPropertyListRef (*orig_SCDynamicStoreCopyValue)(SCDynamicStoreRef, CFStringRef);
static CFPropertyListRef hooked_SCDynamicStoreCopyValue(SCDynamicStoreRef store, CFStringRef key) {
    CFPropertyListRef orig = orig_SCDynamicStoreCopyValue ? orig_SCDynamicStoreCopyValue(store, key) : NULL;
    NSArray *servers = NDSpoofDNSServers();
    if (!servers.count || !NDKeyIsDNSPath(key)) return orig;
    CFDictionaryRef spoofed = NDMakeDNSDict(servers, (orig && CFGetTypeID(orig) == CFDictionaryGetTypeID()) ? (CFDictionaryRef)orig : NULL);
    if (orig) CFRelease(orig);
    return spoofed;
}

static CFDictionaryRef (*orig_SCDynamicStoreCopyMultiple)(SCDynamicStoreRef, CFArrayRef, CFArrayRef);
static CFDictionaryRef hooked_SCDynamicStoreCopyMultiple(SCDynamicStoreRef store, CFArrayRef keys, CFArrayRef patterns) {
    CFDictionaryRef orig = orig_SCDynamicStoreCopyMultiple ? orig_SCDynamicStoreCopyMultiple(store, keys, patterns) : NULL;
    NSArray *servers = NDSpoofDNSServers();
    if (!servers.count || !orig) return orig;
    NSMutableDictionary *out = [(__bridge NSDictionary *)orig mutableCopy];
    BOOL touched = NO;
    for (NSString *k in out.allKeys) {
        if ([k containsString:@"/DNS"]) {
            CFDictionaryRef d = NDMakeDNSDict(servers, (__bridge CFDictionaryRef)out[k]);
            out[k] = CFBridgingRelease(d);
            touched = YES;
        }
    }
    if (!touched) return orig;
    CFRelease(orig);
    return CFBridgingRetain(out);
}

// libresolv: res_9_getservers / res_getservers
typedef union {
    struct sockaddr_in sin;
    struct sockaddr_in6 sin6;
} NDResAddr;

static int NDFillResServers(NDResAddr *set, int cnt, NSArray<NSString *> *servers) {
    if (!set || cnt <= 0 || !servers.count) return 0;
    int n = 0;
    for (NSString *ip in servers) {
        if (n >= cnt) break;
        memset(&set[n], 0, sizeof(set[n]));
        if ([ip containsString:@":"]) {
            set[n].sin6.sin6_len = sizeof(struct sockaddr_in6);
            set[n].sin6.sin6_family = AF_INET6;
            set[n].sin6.sin6_port = htons(53);
            if (inet_pton(AF_INET6, ip.UTF8String, &set[n].sin6.sin6_addr) != 1) continue;
        } else {
            set[n].sin.sin_len = sizeof(struct sockaddr_in);
            set[n].sin.sin_family = AF_INET;
            set[n].sin.sin_port = htons(53);
            if (inet_pton(AF_INET, ip.UTF8String, &set[n].sin.sin_addr) != 1) continue;
        }
        n++;
    }
    return n;
}

static int (*orig_res_9_getservers)(void *statp, void *set, int cnt);
static int hooked_res_9_getservers(void *statp, void *set, int cnt) {
    NSArray *servers = NDSpoofDNSServers();
    if (servers.count && set && cnt > 0) {
        int n = NDFillResServers((NDResAddr *)set, cnt, servers);
        if (n > 0) return n;
    }
    return orig_res_9_getservers ? orig_res_9_getservers(statp, set, cnt) : 0;
}

static int (*orig_res_getservers)(void *statp, void *set, int cnt);
static int hooked_res_getservers(void *statp, void *set, int cnt) {
    NSArray *servers = NDSpoofDNSServers();
    if (servers.count && set && cnt > 0) {
        int n = NDFillResServers((NDResAddr *)set, cnt, servers);
        if (n > 0) return n;
    }
    return orig_res_getservers ? orig_res_getservers(statp, set, cnt) : 0;
}

%ctor {
    NDRunRiskyCHooksAfterUIKitReady(^{
        void *sc = dlsym(RTLD_DEFAULT, "SCDynamicStoreCopyValue");
        if (sc) MSHookFunction(sc, (void *)hooked_SCDynamicStoreCopyValue, (void **)&orig_SCDynamicStoreCopyValue);
        void *scm = dlsym(RTLD_DEFAULT, "SCDynamicStoreCopyMultiple");
        if (scm) MSHookFunction(scm, (void *)hooked_SCDynamicStoreCopyMultiple, (void **)&orig_SCDynamicStoreCopyMultiple);
        void *resolv = dlopen("/usr/lib/libresolv.9.dylib", RTLD_NOW);
        if (!resolv) resolv = dlopen("/usr/lib/libresolv.dylib", RTLD_NOW);
        if (resolv) {
        void *g9 = dlsym(resolv, "res_9_getservers");
        if (g9) MSHookFunction(g9, (void *)hooked_res_9_getservers, (void **)&orig_res_9_getservers);
        void *g = dlsym(resolv, "res_getservers");
        if (g) MSHookFunction(g, (void *)hooked_res_getservers, (void **)&orig_res_getservers);
        }
    });
}
