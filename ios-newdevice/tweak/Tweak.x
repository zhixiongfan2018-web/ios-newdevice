#import <Foundation/Foundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

%ctor {
    @autoreleasepool {
        if (!NDShouldLoadTweak()) return;
        // Venmo: skip profile load / identity state — KeychainRestore is enough
        if (NDIsKeychainOnlyHost()) return;
        NSString *bundleId = [NSBundle mainBundle].bundleIdentifier;
        if (!bundleId.length) return;
        [[NDTweakState shared] reload];
    }
}
