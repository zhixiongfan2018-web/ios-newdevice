#import <Foundation/Foundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

%ctor {
    @autoreleasepool {
        if (!NDShouldLoadTweak()) return;
        // Venmo: still load profile so identity + keychain paths see current record.
        // (MG/C hooks stay gated in their own files; ObjC identity installs delayed.)
        if (NDIsVenmoHost()) {
            [[NDTweakState shared] reload];
            return;
        }
        NSString *bundleId = [NSBundle mainBundle].bundleIdentifier;
        if (!bundleId.length) return;
        [[NDTweakState shared] reload];
    }
}
