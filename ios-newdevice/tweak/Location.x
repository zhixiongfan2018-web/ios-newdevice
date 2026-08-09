#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "NDTweakState.h"

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

%hook CLLocationManager
- (CLLocation *)location {
    CLLocation *fake = NDFakeLocation();
    if (fake) return fake;
    return %orig;
}

- (void)startUpdatingLocation {
    %orig;
    CLLocation *fake = NDFakeLocation();
    id<CLLocationManagerDelegate> delegate = self.delegate;
    if (fake && delegate && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate locationManager:self didUpdateLocations:@[fake]];
        });
    }
}

- (void)requestLocation {
    CLLocation *fake = NDFakeLocation();
    id<CLLocationManagerDelegate> delegate = self.delegate;
    if (fake && delegate && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate locationManager:self didUpdateLocations:@[fake]];
        });
        return;
    }
    %orig;
}
%end
