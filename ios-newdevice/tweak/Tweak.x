#import <Foundation/Foundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

%ctor {
    @autoreleasepool {
        if (!NDShouldLoadTweak()) return;
        // Venmo: skip profile reload here — identity is not spoofed inside Venmo
        // (MG hooks crash). KeychainRestore handles session bind alone.
        if (NDIsVenmoHost()) return;
        NSString *bundleId = [NSBundle mainBundle].bundleIdentifier;
        if (!bundleId.length) return;
        [[NDTweakState shared] reload];
    }
}
