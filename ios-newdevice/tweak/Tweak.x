#import <Foundation/Foundation.h>
#import "NDTweakState.h"

%ctor {
    @autoreleasepool {
        NSString *bundleId = [NSBundle mainBundle].bundleIdentifier;
        if (!bundleId.length) return;
        [[NDTweakState shared] reload];
    }
}
