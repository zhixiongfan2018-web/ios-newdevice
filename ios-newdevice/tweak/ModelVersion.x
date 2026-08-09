#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <string.h>
#import <substrate.h>
#import "NDTweakState.h"

%hook UIDevice
- (NSString *)model {
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
%end

%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeCarrier && st.profile.RadioAccess.length) {
        NSString *r = st.profile.RadioAccess;
        if ([r isEqualToString:@"LTE"]) return CTRadioAccessTechnologyLTE;
        if ([r isEqualToString:@"WCDMA"]) return CTRadioAccessTechnologyWCDMA;
        if ([r isEqualToString:@"NR"] || [r isEqualToString:@"NRNSA"]) {
            return @"CTRadioAccessTechnologyNR";
        }
        return CTRadioAccessTechnologyLTE;
    }
    return %orig;
}
%end

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.fakeDeviceModel && name && oldp && oldlenp) {
        if (strcmp(name, "hw.machine") == 0 && st.profile.HardwareMachine.length) {
            const char *v = st.profile.HardwareMachine.UTF8String;
            size_t len = strlen(v) + 1;
            if (*oldlenp < len) {
                *oldlenp = len;
                return 0;
            }
            memcpy(oldp, v, len);
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
    }
    return ret;
}

%ctor {
    MSHookFunction((void *)sysctlbyname, (void *)hooked_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)uname, (void *)hooked_uname, (void **)&orig_uname);
}
