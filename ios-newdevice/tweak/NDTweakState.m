#import "NDTweakState.h"
#import "NDRecordStore.h"
#import "NDPaths.h"
#import "NDSafeLoad.h"
#import <notify.h>

@implementation NDTweakState {
    int _token;
}

+ (instancetype)shared {
    static NDTweakState *state;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        state = [NDTweakState new];
        state.bundleId = [NSBundle mainBundle].bundleIdentifier ?: @"";
        // Never activate spoof inside Sileo / Dopamine / package managers
        if (NDBundleIsJailbreakTool(state.bundleId)) {
            state.active = NO;
            return;
        }
        [state reload];
        notify_register_dispatch([NDNotifyReload UTF8String], &state->_token, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            [state reload];
        });
    });
    return state;
}

- (void)reload {
    if (NDBundleIsJailbreakTool(self.bundleId)) {
        self.active = NO;
        self.identityHost = NO;
        return;
    }
    [[NDConfig shared] reload];
    self.config = [NDConfig shared];
    self.profile = [[NDRecordStore shared] currentProfile];
    // Only the explicit "原始机器" record means passthrough — do NOT treat empty IDFA alone
    // as original (legacy/corrupt profiles would silently disable spoof).
    BOOL isOriginal = [self.profile.name isEqualToString:@"原始机器"];
    BOOL targeted = [self.config isTargetApp:self.bundleId];
    NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
    BOOL isCommCenter = [proc isEqualToString:@"CommCenter"]
        || [proc isEqualToString:@"CommCenterRootHelper"]
        || [self.bundleId isEqualToString:@"com.apple.CommCenter"];
    self.identityHost = isCommCenter;
    BOOL profileOK = !isOriginal && self.profile.enabled && self.profile != nil;
    // spoofDeviceIdentity defaults YES for old profiles (nil/missing key → YES via load)
    BOOL allowSpoof = self.profile.spoofDeviceIdentity;
    self.active = targeted && profileOK && allowSpoof;
}

- (BOOL)shouldSpoof {
    if ([self.profile.name isEqualToString:@"原始机器"]) return NO;
    return self.active && self.profile != nil && self.profile.spoofDeviceIdentity;
}

- (BOOL)shouldSpoofIdentity {
    // Target apps + telephony daemons (baseband-adjacent IMEI / equipment info)
    if (!self.profile || [self.profile.name isEqualToString:@"原始机器"]) return NO;
    if (!self.profile.spoofDeviceIdentity) return NO;
    return self.active || self.identityHost;
}

@end
