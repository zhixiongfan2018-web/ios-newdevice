#import <Foundation/Foundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

%group NDTimeBoot
%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.spoofLocation && st.profile.TimeZone.length) {
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:st.profile.TimeZone];
        if (tz) return tz;
    }
    return %orig;
}

+ (NSTimeZone *)localTimeZone {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.spoofLocation && st.profile.TimeZone.length) {
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:st.profile.TimeZone];
        if (tz) return tz;
    }
    return %orig;
}

+ (NSTimeZone *)defaultTimeZone {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.spoofLocation && st.profile.TimeZone.length) {
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:st.profile.TimeZone];
        if (tz) return tz;
    }
    return %orig;
}
%end
%end // NDTimeBoot

%ctor {
    if (NDIsPrizePicksHost()) return;
    NDRunAfterUIKitReady(^{
        %init(NDTimeBoot);
    });
}
