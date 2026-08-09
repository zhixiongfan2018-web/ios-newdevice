#import "NDTweakState.h"
#import "NDRecordStore.h"
#import "NDPaths.h"
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
        [state reload];
        notify_register_dispatch([NDNotifyReload UTF8String], &state->_token, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            [state reload];
        });
    });
    return state;
}

- (void)reload {
    [[NDConfig shared] reload];
    self.config = [NDConfig shared];
    self.profile = [[NDRecordStore shared] currentProfile];
    BOOL isOriginal = [self.profile.name isEqualToString:@"原始机器"] || self.profile.IDFA.length == 0;
    BOOL targeted = [self.config isTargetApp:self.bundleId];
    self.active = targeted && !isOriginal && self.profile.enabled;
}

- (BOOL)shouldSpoof {
    return self.active && self.profile != nil;
}

@end
