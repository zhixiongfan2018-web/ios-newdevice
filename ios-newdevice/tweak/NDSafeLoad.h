#ifndef NDSafeLoad_h
#define NDSafeLoad_h

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <string.h>

/// Return YES if NewDevice tweak must NOT load in this process.
/// Keeps Sileo / Dopamine / package managers stable so jailbreak tooling is not disrupted.
static inline BOOL NDBundleIsJailbreakTool(NSString *bundleId) {
    // Empty bundle id is common for daemons (e.g. CommCenter) — not a jailbreak tool by itself.
    if (!bundleId.length) return NO;
    static NSSet<NSString *> *deny;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        deny = [NSSet setWithArray:@[
            @"com.local.newdevice",
            @"xyz.willy.Sileo",
            @"org.coolstar.SileoStore",
            @"org.coolstar.SileoNightly",
            @"com.saurik.Cydia",
            @"xyz.willy.Zebra",
            @"com.getzbra.zebra",
            @"com.opa334.Dopamine",
            @"com.opa334.TrollStore",
            @"com.opa334.TrollHelper",
            @"org.coolstar.SafeMode",
        ]];
    });
    if ([deny containsObject:bundleId]) return YES;
    if ([bundleId hasPrefix:@"com.local.newdevice"]) return YES;
    if ([bundleId hasPrefix:@"xyz.willy.Sileo"]) return YES;
    if ([bundleId hasPrefix:@"com.opa334.Dopamine"]) return YES;
    NSString *lower = bundleId.lowercaseString;
    if ([lower containsString:@"sileo"]) return YES;
    if ([lower containsString:@"cydia"]) return YES;
    if ([lower containsString:@"zebra"]) return YES;
    return NO;
}

/// CommCenter / SpringBoard may spoof IMEI + gestalt. Never treat Safari as a host —
/// injecting into MobileSafari historically SIGILL/SIGBUS on iOS 18 + ElleKit.
static inline BOOL NDIsSystemIdentityHost(void) {
    NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
    if ([proc isEqualToString:@"CommCenter"] || [proc isEqualToString:@"CommCenterRootHelper"]) return YES;
    if ([proc isEqualToString:@"SpringBoard"]) return YES;
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid isEqualToString:@"com.apple.springboard"]) return YES;
    if ([bid isEqualToString:@"com.apple.CommCenter"]) return YES;
    return NO;
}

static inline BOOL NDShouldLoadTweak(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (NDBundleIsJailbreakTool(bid)) return NO;
    // Empty bundle id is common in very early %ctor (CommCenter) — do NOT refuse.
    if (!bid.length) return YES;
    // Apple UI apps (Safari, Settings, …) crash with MG/sysctl hooks. SpringBoard is ok.
    if ([bid hasPrefix:@"com.apple."] && ![bid isEqualToString:@"com.apple.springboard"]
        && ![bid isEqualToString:@"com.apple.CommCenter"]) {
        return NO;
    }
    return YES;
}

/// Venmo needs identity + in-app Keychain to land logged-in after import.
static inline BOOL NDIsVenmoHost(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid isEqualToString:@"net.kortina.labs.Venmo"]) return YES;
    NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
    if ([proc isEqualToString:@"Venmo"]) return YES;
    return NO;
}

/// PrizePicks (pz) SIGBUS/SIGILL with UIDevice.name / MG / jailbreak-hide ObjC — same as Venmo.
static inline BOOL NDIsPrizePicksHost(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid isEqualToString:@"com.myprizepicks.prizepicks"]) return YES;
    NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
    if ([proc isEqualToString:@"PrizePicks"]) return YES;
    return NO;
}

/// IDFA/IDFV ObjC only, delayed. No MG, no UIDevice.name, no JailbreakHide.
static inline BOOL NDIsSoftIdentityHost(void) {
    return NDIsVenmoHost() || NDIsPrizePicksHost();
}

/// AMG already owns MG/UIDevice in the same process — double-hook = Venmo SIGBUS/PAC.
/// Prefer excluding targets from amg.plist (syncInjectFilter); this is the runtime safety net.
static inline BOOL NDAmgDylibLoaded(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        // Match rootless + classic paths: .../amg.dylib
        if (strstr(name, "amg.dylib") != NULL) return YES;
    }
    return NO;
}

/// Pending one-shot ops for Venmo (world-readable under jb + Media).
/// Outside processes cannot delete Venmo Keychain; only Venmo-in-process SecItemDelete can.
static inline BOOL NDVenmoPendingClearKeychain(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in @[
             @"/var/jb/Library/NewDevice/pending-clear-kc/net.kortina.labs.Venmo",
             @"/var/mobile/Media/NewDevice/pending-clear-kc/net.kortina.labs.Venmo",
         ]) {
        if ([fm fileExistsAtPath:p]) return YES;
    }
    return NO;
}

static inline BOOL NDVenmoPendingAkcRestore(void) {
    // Only explicit pending pointers — live Documents/akc.plist alone must NOT
    // keep re-entering KeychainRestore on every cold launch.
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in @[
             @"/var/jb/Library/NewDevice/pending-akc/net.kortina.labs.Venmo.txt",
             @"/var/mobile/Media/NewDevice/pending-akc/net.kortina.labs.Venmo.txt",
         ]) {
        if ([fm fileExistsAtPath:p]) return YES;
    }
    return NO;
}

/// Legacy alias.
static inline BOOL NDIsKeychainOnlyHost(void) {
    return NDIsVenmoHost();
}

/// ObjC / UIKit hooks for non-Venmo hosts. Must NOT install before UIApplication init
/// (ElleKit + iOS 18 crashes inside _UIApplicationInfoParser when swizzled early).
static inline void NDRunAfterUIKitReady(void (^block)(void)) {
    if (!block) return;
    if (!NDShouldLoadTweak()) return;
    // Venmo / PrizePicks use delayed IDFA-only hooks (full ObjC set crashes pz).
    if (NDIsSoftIdentityHost()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NDIsSoftIdentityHost()) return;
        if (!NDShouldLoadTweak()) return;
        block();
    });
}

/// AMG-style identity for Venmo: ObjC hooks only, delayed past mParticle / UIKit init.
/// Early ASIdentifier / UIDevice hooks historically SIGBUS'd Venmo on iOS 18.
static inline void NDRunVenmoSafeObjCHooksAfterReady(void (^block)(void)) {
    if (!block) return;
    if (!NDShouldLoadTweak()) return;
    void (^run)(void) = ^{
        @try {
            if (!NDShouldLoadTweak()) return;
            block();
        } @catch (__unused NSException *ex) {
        }
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!NDShouldLoadTweak()) return;
        if (NDIsSoftIdentityHost()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), run);
        } else {
            run();
        }
    });
}

/// C/MSHookFunction hooks that previously SIGILL'd Venmo on iOS 18 + ElleKit
/// (getifaddrs / statfs / DNS / IOKit / sysctl). Skip Venmo AND third-party
/// targets (Safari/Kalshi/FanDuel) — only SpringBoard / CommCenter.
static inline void NDRunRiskyCHooksAfterUIKitReady(void (^block)(void)) {
    if (!block) return;
    if (!NDShouldLoadTweak()) return;
    if (NDIsSoftIdentityHost()) return;
    if (!NDIsSystemIdentityHost()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NDIsSoftIdentityHost()) return;
        if (!NDShouldLoadTweak()) return;
        if (!NDIsSystemIdentityHost()) return;
        block();
    });
}

#endif /* NDSafeLoad_h */
