#import <Foundation/Foundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

%ctor {
    @autoreleasepool {
        if (!NDShouldLoadTweak()) return;
        // Venmo must load profile too — identity spoof + keychain restore together.
        NSString *bundleId = [NSBundle mainBundle].bundleIdentifier;
        if (!bundleId.length && !NDIsVenmoHost()) return;
        [[NDTweakState shared] reload];
    }
}
