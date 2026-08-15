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
    NSURL *url = [NSURL URLWithString:@"https://api.ipify.org?format=text"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSString *ip = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        ip = [ip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        completion(ip, nil);
    }];
    [task resume];
}

@end
