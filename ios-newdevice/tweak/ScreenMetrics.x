#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"
#import "NDDeviceCatalog+Metrics.h"

static CGRect NDSpoofBounds(void) {
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof] || !st.config.fakeDeviceModel) return CGRectZero;
    NSDictionary *m = [NDDeviceCatalog displayMetricsForProductType:st.profile.ProductType];
    if (!m) return CGRectZero;
    return CGRectMake(0, 0, [m[@"w"] doubleValue], [m[@"h"] doubleValue]);
}

static CGFloat NDSpoofScale(void) {
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof] || !st.config.fakeDeviceModel) return 0;
    NSDictionary *m = [NDDeviceCatalog displayMetricsForProductType:st.profile.ProductType];
    return m ? [m[@"scale"] doubleValue] : 0;
}

%group NDScreenMetrics
%hook UIScreen
- (CGRect)bounds {
    CGRect spoof = NDSpoofBounds();
    if (!CGRectIsEmpty(spoof)) return spoof;
    return %orig;
}
- (CGRect)nativeBounds {
    CGRect spoof = NDSpoofBounds();
    CGFloat scale = NDSpoofScale();
    if (!CGRectIsEmpty(spoof) && scale > 0) {
        return CGRectMake(0, 0, spoof.size.width * scale, spoof.size.height * scale);
    }
    return %orig;
}
- (CGFloat)scale {
    CGFloat s = NDSpoofScale();
    return s > 0 ? s : %orig;
}
- (CGFloat)nativeScale {
    CGFloat s = NDSpoofScale();
    return s > 0 ? s : %orig;
}
- (CGFloat)brightness {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.profile.Brightness >= 0.0f && st.profile.Brightness <= 1.0f) {
        return st.profile.Brightness;
    }
    return %orig;
}
%end
%end // NDScreenMetrics

%ctor {
    // UIScreen bounds/scale spoof feeds CoreUI getDeviceTraits — SIGILL in PrizePicks.
    if (NDIsPrizePicksHost()) return;
    NDRunAfterUIKitReady(^{
        %init(NDScreenMetrics);
    });
}
