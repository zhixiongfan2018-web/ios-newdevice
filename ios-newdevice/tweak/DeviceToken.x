#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

static NSData *NDDeviceTokenData(NSString *hex) {
    if (!hex.length) return nil;
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@" " withString:@""]
                       stringByReplacingOccurrencesOfString:@"<" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@">" withString:@""];
    if (clean.length % 2 != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:clean.length / 2];
    uint8_t *bytes = data.mutableBytes;
    const char *c = clean.UTF8String;
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned int b = 0;
        if (sscanf(c + i * 2, "%2x", &b) != 1) return nil;
        bytes[i] = (uint8_t)b;
    }
    return data;
}

static void NDDeliverSpoofedToken(UIApplication *app) {
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof] || !st.profile.DeviceToken.length) return;
    NSData *token = NDDeviceTokenData(st.profile.DeviceToken);
    if (!token.length) return;
    id del = app.delegate;
    SEL sel = @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:);
    if (!del || ![del respondsToSelector:sel]) return;
    NSMethodSignature *sig = [del methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    inv.target = del;
    UIApplication *a = app;
    [inv setArgument:&a atIndex:2];
    [inv setArgument:&token atIndex:3];
    [inv invoke];
}

%group NDDeviceToken
%hook UIApplication
- (void)registerForRemoteNotifications {
    %orig;
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof] || !st.profile.DeviceToken.length) return;
    UIApplication *app = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NDDeliverSpoofedToken(app);
    });
}
%end

%hook NSUserDefaults
- (id)objectForKey:(NSString *)defaultName {
    id v = %orig;
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof] || !st.profile.DeviceToken.length) return v;
    if (![defaultName isKindOfClass:[NSString class]]) return v;
    NSString *l = defaultName.lowercaseString;
    if ([l containsString:@"devicetoken"] || [l isEqualToString:@"device_token"] || [l isEqualToString:@"apns_token"]) {
        return st.profile.DeviceToken;
    }
    return v;
}
%end
%end // NDDeviceToken

%ctor {
    if (NDIsPrizePicksHost()) return;
    NDRunAfterUIKitReady(^{
        %init(NDDeviceToken);
    });
}
