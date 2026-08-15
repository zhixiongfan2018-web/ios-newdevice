#import "NDAirplane.h"
#import <objc/runtime.h>
#import <dlfcn.h>

@implementation NDAirplane

+ (BOOL)setAirplaneModeOn:(BOOL)on {
    // Best-effort via RadiosPreferences private API when linked/available
    Class RadiosPreferences = NSClassFromString(@"RadiosPreferences");
    if (!RadiosPreferences) {
        void *handle = dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY);
        (void)handle;
        RadiosPreferences = NSClassFromString(@"RadiosPreferences");
    }
    if (!RadiosPreferences) return NO;
    id prefs = [RadiosPreferences new];
    if (!prefs) return NO;
    if ([prefs respondsToSelector:NSSelectorFromString(@"setAirplaneMode:")]) {
        NSMethodSignature *sig = [prefs methodSignatureForSelector:NSSelectorFromString(@"setAirplaneMode:")];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = NSSelectorFromString(@"setAirplaneMode:");
        inv.target = prefs;
        BOOL value = on;
        [inv setArgument:&value atIndex:2];
        [inv invoke];
        if ([prefs respondsToSelector:NSSelectorFromString(@"synchronize")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [prefs performSelector:NSSelectorFromString(@"synchronize")];
#pragma clang diagnostic pop
        }
        return YES;
    }
    return NO;
}

+ (BOOL)toggleAirplaneWithDelay:(NSTimeInterval)delay error:(NSError **)error {
    // Keep on/off settle proportional to caller delay (switch uses ~0.6s; tools may pass longer).
    NSTimeInterval onHold = MAX(0.4, delay);
    NSTimeInterval offSettle = MAX(0.4, MIN(1.2, delay));
    BOOL ok1 = [self setAirplaneModeOn:YES];
    [NSThread sleepForTimeInterval:onHold];
    BOOL ok2 = [self setAirplaneModeOn:NO];
    [NSThread sleepForTimeInterval:offSettle];
    if (!ok1 || !ok2) {
        if (error) {
            *error = [NSError errorWithDomain:@"NDAirplane" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Airplane toggle unavailable; toggle manually"}];
        }
        return NO;
    }
    return YES;
}

+ (void)fetchPublicIPWithCompletion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    [self fetchIPGeolocationWithCompletion:^(NSDictionary *info, NSError *error) {
        if (completion) completion(info[@"ip"], error);
    }];
}

+ (void)fetchIPGeolocationWithCompletion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    // geojs: HTTPS, no key, returns lat/lon/timezone for the egress IP.
    NSURL *url = [NSURL URLWithString:@"https://get.geojs.io/v1/ip/geo.json"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data.length) {
            // Fallback: ipify + ip-api (HTTP)
            [self NDFetchGeoFallback:completion];
            return;
        }
        NSDictionary *raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![raw isKindOfClass:[NSDictionary class]]) {
            [self NDFetchGeoFallback:completion];
            return;
        }
        double lat = [raw[@"latitude"] doubleValue];
        double lon = [raw[@"longitude"] doubleValue];
        if (fabs(lat) < 0.01 && fabs(lon) < 0.01) {
            [self NDFetchGeoFallback:completion];
            return;
        }
        NSDictionary *info = @{
            @"ip": raw[@"ip"] ?: @"",
            @"lat": @(lat),
            @"lon": @(lon),
            @"timezone": raw[@"timezone"] ?: @"",
            @"city": raw[@"city"] ?: @"",
            @"countryCode": raw[@"country_code"] ?: @"",
            @"isp": raw[@"organization_name"] ?: (raw[@"organization"] ?: @""),
        };
        if (completion) completion(info, nil);
    }];
    [task resume];
}

+ (void)NDFetchGeoFallback:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSURL *url = [NSURL URLWithString:@"http://ip-api.com/json/?fields=status,message,query,country,countryCode,city,lat,lon,timezone,isp"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data.length) {
            if (completion) completion(nil, error ?: [NSError errorWithDomain:@"NDAirplane" code:2 userInfo:@{NSLocalizedDescriptionKey: @"geo failed"}]);
            return;
        }
        NSDictionary *raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![raw isKindOfClass:[NSDictionary class]] || ![raw[@"status"] isEqualToString:@"success"]) {
            if (completion) completion(nil, [NSError errorWithDomain:@"NDAirplane" code:3 userInfo:@{NSLocalizedDescriptionKey: raw[@"message"] ?: @"geo failed"}]);
            return;
        }
        NSDictionary *info = @{
            @"ip": raw[@"query"] ?: @"",
            @"lat": raw[@"lat"] ?: @0,
            @"lon": raw[@"lon"] ?: @0,
            @"timezone": raw[@"timezone"] ?: @"",
            @"city": raw[@"city"] ?: @"",
            @"countryCode": raw[@"countryCode"] ?: @"",
            @"isp": raw[@"isp"] ?: @"",
        };
        if (completion) completion(info, nil);
    }];
    [task resume];
}

+ (NSDictionary *)fetchIPGeolocationSync {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *out = nil;
    [self fetchIPGeolocationWithCompletion:^(NSDictionary *info, NSError *error) {
        (void)error;
        out = info;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)));
    return out;
}

@end
