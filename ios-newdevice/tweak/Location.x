#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

static CLLocation *NDFakeLocation(void) {
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof] || !st.config.spoofLocation) return nil;
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(st.profile.Latitude, st.profile.Longitude);
    if (coord.latitude == 0 && coord.longitude == 0) return nil;
    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:st.profile.Altitude
                               horizontalAccuracy:5.0
                                 verticalAccuracy:5.0
                                           course:0
                                            speed:0
                                        timestamp:[NSDate date]];
}

static void NDDeliverFake(CLLocationManager *manager) {
    CLLocation *fake = NDFakeLocation();
    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if (!fake || !delegate) return;
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate locationManager:manager didUpdateLocations:@[fake]];
        });
    }
}

%group NDLocation
%hook CLLocationManager
- (CLLocation *)location {
    CLLocation *fake = NDFakeLocation();
    if (fake) return fake;
    return %orig;
}

- (void)startUpdatingLocation {
    if (NDFakeLocation()) {
        // Avoid racing real GPS callbacks against the spoofed fix
        NDDeliverFake(self);
        return;
    }
    %orig;
}

- (void)startUpdatingHeading {
    if (NDFakeLocation()) {
        return;
    }
    %orig;
}

- (void)requestLocation {
    if (NDFakeLocation()) {
        NDDeliverFake(self);
        return;
    }
    %orig;
}

- (void)requestWhenInUseAuthorization {
    %orig;
    if (NDFakeLocation()) {
        NDDeliverFake(self);
    }
}

- (void)requestAlwaysAuthorization {
    %orig;
    if (NDFakeLocation()) {
        NDDeliverFake(self);
    }
}
%end
%end // NDLocation

%ctor {
    NDRunAfterUIKitReady(^{
        if (NDPrizePicksSkipHeavyHooks()) return;
        %init(NDLocation);
    });
}
