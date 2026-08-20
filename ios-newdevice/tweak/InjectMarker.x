#import <Foundation/Foundation.h>
#import "NDSafeLoad.h"

/// Earliest possible injection marker — must not depend on other NewDevice modules.
/// If this file's marker appears but nd-akc-ok does not, later %ctors are crashing on load.

__attribute__((constructor(101)))
static void NDInjectMarkerCtor(void) {
    @autoreleasepool {
        @try {
            NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
            if (NDBundleIsJailbreakTool(bid)) return;
            NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
            if (!bid.length && ![proc isEqualToString:@"SpringBoard"]) {
                // Very early — retry lightly via dispatch if available
            }
            if ([bid hasPrefix:@"com.apple."] &&
                ![bid isEqualToString:@"com.apple.springboard"] &&
                ![bid containsString:@"mobilesafari"]) {
                return;
            }
            if ([bid isEqualToString:@"com.myprizepicks.prizepicks"]) return;

            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *line = [NSString stringWithFormat:@"bid=%@\nproc=%@\ntime=%@\nctor=InjectMarker\n",
                              bid.length ? bid : @"(empty)", proc, [NSDate date]];

            NSString *homeDocs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
            if (bid.length && ![bid hasPrefix:@"com.apple.springboard"]) {
                [fm createDirectoryAtPath:homeDocs withIntermediateDirectories:YES attributes:nil error:nil];
                [line writeToFile:[homeDocs stringByAppendingPathComponent:@"nd-tweak-loaded.txt"]
                       atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }

            for (NSString *dir in @[
                     @"/var/jb/Library/NewDevice",
                     @"/var/mobile/Media/NewDevice",
                 ]) {
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                [line writeToFile:[dir stringByAppendingPathComponent:@"last-tweak-loaded.txt"]
                       atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        } @catch (__unused NSException *ex) {
        }
    }
}
