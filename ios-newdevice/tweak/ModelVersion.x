#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <string.h>
#import <substrate.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

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
    if ([st shouldSpoof] && st.config.fakeDeviceModel && st.profile.Model.length) {
        return @"iPhone";
    }
    return %orig;
}

- (NSString *)localizedModel {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeDeviceModel && st.profile.Model.length) {
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
        // Fallback single-service dict when orig is empty
        return @{@"0000000100000001": mapped};
    }
    return %orig;
}
%end

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeDeviceModel && name && oldp && oldlenp) {
        const char *spoof = NULL;
        if (strcmp(name, "hw.machine") == 0 && st.profile.HardwareMachine.length) {
            spoof = st.profile.HardwareMachine.UTF8String;
        } else if (strcmp(name, "hw.model") == 0 && st.profile.HardwareMachine.length) {
            // Many apps probe hw.model; return ProductType-style machine id for consistency
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
