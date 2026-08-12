#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/time.h>
#import <string.h>
#import <substrate.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"
#import "NDDeviceCatalog+Metrics.h"

static NSString *NDMappedRadioAccess(NSString *r) {
    if (!r.length) return nil;
    if ([r isEqualToString:@"LTE"]) return CTRadioAccessTechnologyLTE;
    if ([r isEqualToString:@"WCDMA"]) return CTRadioAccessTechnologyWCDMA;
    if ([r isEqualToString:@"NR"]) return @"NR";
    if ([r isEqualToString:@"NRNSA"]) return @"NRNSA";
    if ([r isEqualToString:@"GPRS"]) return CTRadioAccessTechnologyGPRS;
    if ([r isEqualToString:@"Edge"]) return CTRadioAccessTechnologyEdge;
    if ([r isEqualToString:@"HSDPA"]) return CTRadioAccessTechnologyHSDPA;
    return CTRadioAccessTechnologyLTE;
}

%hook UIDevice
- (NSString *)model {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeDeviceModel && st.profile.ProductType.length) {
        if ([st.profile.ProductType hasPrefix:@"iPad"]) return @"iPad";
        return @"iPhone";
    }
    return %orig;
}

- (NSString *)localizedModel {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeDeviceModel && st.profile.ProductType.length) {
        if ([st.profile.ProductType hasPrefix:@"iPad"]) return @"iPad";
        return @"iPhone";
    }
    return %orig;
}

- (NSString *)systemVersion {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeSystemVer && st.profile.SystemVer.length) {
        return st.profile.SystemVer;
    }
    return %orig;
}

- (NSString *)systemName {
    return %orig;
}
%end

%hook CTCarrier
- (NSString *)carrierName {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeCarrier && st.profile.Carrier.length) {
        return st.profile.Carrier;
    }
    return %orig;
}
- (NSString *)mobileCountryCode {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeCarrier && st.profile.MCC.length) {
        return st.profile.MCC;
    }
    return %orig;
}
- (NSString *)mobileNetworkCode {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeCarrier && st.profile.MNC.length) {
        return st.profile.MNC;
    }
    return %orig;
}
- (NSString *)isoCountryCode {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeCarrier) {
        return @"us";
    }
    return %orig;
}
- (BOOL)allowsVOIP {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeCarrier) return YES;
    return %orig;
}
%end

%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeCarrier && st.profile.RadioAccess.length) {
        return NDMappedRadioAccess(st.profile.RadioAccess);
    }
    return %orig;
}

- (NSDictionary *)serviceCurrentRadioAccessTechnology {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeCarrier && st.profile.RadioAccess.length) {
        NSString *mapped = NDMappedRadioAccess(st.profile.RadioAccess);
        NSDictionary *orig = %orig;
        if ([orig isKindOfClass:[NSDictionary class]] && orig.count) {
            NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:orig.count];
            for (id key in orig) {
                out[key] = mapped;
            }
            return out;
        }
        return @{@"0000000100000001": mapped};
    }
    return %orig;
}

- (CTCarrier *)subscriberCellularProvider {
    NDTweakState *st = [NDTweakState shared];
    CTCarrier *orig = %orig;
    if ([st shouldSpoof] && st.config.fakeCarrier && orig) return orig; // property hooks on CTCarrier cover fields
    return orig;
}

- (NSDictionary *)serviceSubscriberCellularProviders {
    NDTweakState *st = [NDTweakState shared];
    NSDictionary *orig = %orig;
    if (![st shouldSpoof] || !st.config.fakeCarrier) return orig;
    if (![orig isKindOfClass:[NSDictionary class]] || !orig.count) {
        // Fabricate a single-service map so probes see spoofed carrier via CTCarrier hooks
        return orig ?: @{};
    }
    return orig; // values are CTCarrier instances; their getters are hooked
}
%end

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && name && oldp && oldlenp) {
        if (st.config.fakeDeviceModel) {
            const char *spoof = NULL;
            if (strcmp(name, "hw.machine") == 0 && st.profile.HardwareMachine.length) {
                spoof = st.profile.HardwareMachine.UTF8String;
            } else if (strcmp(name, "hw.model") == 0 && st.profile.HardwareMachine.length) {
                spoof = st.profile.HardwareMachine.UTF8String;
            }
            if (spoof) {
                size_t len = strlen(spoof) + 1;
                if (*oldlenp < len) {
                    *oldlenp = len;
                    return 0;
                }
                memcpy(oldp, spoof, len);
                *oldlenp = len;
                return 0;
            }
        }
        // AMG-style uptime fingerprint: spoof kern.boottime
        if (strcmp(name, "kern.boottime") == 0 && st.profile.BootTime > 0) {
            struct timeval tv;
            memset(&tv, 0, sizeof(tv));
            tv.tv_sec = (time_t)st.profile.BootTime;
            tv.tv_usec = 0;
            if (*oldlenp < sizeof(tv)) {
                *oldlenp = sizeof(tv);
                return 0;
            }
            memcpy(oldp, &tv, sizeof(tv));
            *oldlenp = sizeof(tv);
            return 0;
        }
        if (st.config.fakeDeviceModel && (strcmp(name, "hw.memsize") == 0 || strcmp(name, "hw.physmem") == 0)) {
            uint64_t mem = st.profile.PhysicalMemory > 0
                ? st.profile.PhysicalMemory
                : [NDDeviceCatalog memoryBytesForProductType:st.profile.ProductType];
            if (mem > 0) {
                if (*oldlenp < sizeof(mem)) {
                    *oldlenp = sizeof(mem);
                    return 0;
                }
                memcpy(oldp, &mem, sizeof(mem));
                *oldlenp = sizeof(mem);
                return 0;
            }
        }
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int (*orig_uname)(struct utsname *);
static int hooked_uname(struct utsname *buf) {
    int ret = orig_uname(buf);
    NDTweakState *st = [NDTweakState shared];
    if (ret == 0 && buf && [st shouldSpoof] && st.config.fakeDeviceModel && st.profile.HardwareMachine.length) {
        strncpy(buf->machine, st.profile.HardwareMachine.UTF8String, sizeof(buf->machine) - 1);
        buf->machine[sizeof(buf->machine) - 1] = '\0';
    }
    return ret;
}

%ctor {
    if (!NDShouldLoadTweak()) return;
    MSHookFunction((void *)sysctlbyname, (void *)hooked_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)uname, (void *)hooked_uname, (void **)&orig_uname);
}
