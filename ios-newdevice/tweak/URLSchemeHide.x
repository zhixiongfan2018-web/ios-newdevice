#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

static BOOL NDIsJBURLScheme(NSString *scheme) {
    if (!scheme.length) return NO;
    NSString *s = scheme.lowercaseString;
    static NSArray<NSString *> *banned;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        banned = @[
            @"cydia", @"sileo", @"zbra", @"zebra", @"filza", @"undecimus",
            @"activator", @"preferences", @"app-prefs", @"dopamine", @"palera1n",
            @"trollstore", @"apple-magnifier", @"santander", @"shadow",
        ];
    });
    for (NSString *b in banned) {
        if ([s isEqualToString:b] || [s hasPrefix:[b stringByAppendingString:@"-"]]) return YES;
    }
    return NO;
}

%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideBasic && url.scheme.length && NDIsJBURLScheme(url.scheme)) {
        return NO;
    }
    return %orig;
}
%end

%ctor {
    if (!NDShouldLoadTweak()) return;
}
