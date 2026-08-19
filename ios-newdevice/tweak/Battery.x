#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

%group NDBattery
%hook UIDevice
- (float)batteryLevel {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.BatteryLevel >= 0.0f && st.profile.BatteryLevel <= 1.0f) {
        return st.profile.BatteryLevel;
    }
    return %orig;
}
- (UIDeviceBatteryState)batteryState {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.BatteryLevel >= 0.0f) {
        // Prefer unplugged/not charging for a "normal phone" fingerprint
        return UIDeviceBatteryStateUnplugged;
    }
    return %orig;
}
- (BOOL)isBatteryMonitoringEnabled {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.BatteryLevel >= 0.0f) return YES;
    return %orig;
}
%end
%end // NDBattery

%ctor {
    if (NDIsPrizePicksHost()) return;
    NDRunAfterUIKitReady(^{
        %init(NDBattery);
    });
}
