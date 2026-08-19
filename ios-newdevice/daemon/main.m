#import <Foundation/Foundation.h>
#import "NDHTTPServer.h"
#import "NDPaths.h"
#import "NDRecordStore.h"
#import "NDRuntimeState.h"
#import "NDConfig.h"
#import "NDAppDataManager.h"
#import <errno.h>
#import <string.h>
#import <unistd.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [NDPaths ensureDirectories];

        // One-shot: force-quit target apps as root (App UI cannot reliably killall).
        if (argc >= 3 && argv[1] && strcmp(argv[1], "kill-apps") == 0) {
            NSString *csv = [NSString stringWithUTF8String:argv[2]] ?: @"";
            NSMutableArray *bids = [NSMutableArray array];
            for (NSString *part in [csv componentsSeparatedByString:@","]) {
                NSString *b = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (b.length) [bids addObject:b];
            }
            [[NDAppDataManager shared] terminateApps:bids];
            NSString *body = [NSString stringWithFormat:@"killed=%lu\n%@", (unsigned long)bids.count, csv];
            [body writeToFile:@"/var/mobile/Media/NewDevice/last-terminate-apps.txt"
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fprintf(stdout, "%s\n", body.UTF8String ?: "");
            return 0;
        }

        // One-shot: clear Venmo keychain with daemon entitlements (App UI cannot).
        if (argc >= 2 && argv[1] && strcmp(argv[1], "clear-venmo-kc") == 0) {
            NSString *body = [[NDAppDataManager shared] clearVenmoKeychainAllKnownGroups] ?: @"";
            [body writeToFile:@"/var/mobile/Media/NewDevice/last-keychain-clear.txt"
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fprintf(stdout, "%s\n", body.UTF8String ?: "");
            return 0;
        }

        // One-shot (postinst / root shell): sole-owner inject filter + exclude from amg.plist.
        if (argc >= 2 && argv[1] && strcmp(argv[1], "sync-inject") == 0) {
            [[NDConfig shared] reload];
            NSArray *targets = [NDConfig shared].targetApps ?: @[];
            if (!targets.count) {
                targets = @[ @"net.kortina.labs.Venmo" ];
            }
            NSString *body = [[NDAppDataManager shared] syncInjectFilterWithTargetApps:targets] ?: @"";
            [body writeToFile:@"/var/mobile/Media/NewDevice/last-inject-filter.txt"
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fprintf(stdout, "%s\n", body.UTF8String ?: "");
            return body.length ? 0 : 1;
        }

        // Publish world-readable runtime snapshot at boot so sandboxed target apps
        // can spoof even before the NewDevice UI is opened.
        void (^publishRuntime)(void) = ^{
            @try {
                [[NDRecordStore shared] notifyReload];
            } @catch (__unused NSException *e) {
                NSLog(@"[newdeviced] runtime publish failed: %@", e);
                NDConfig *cfg = [NDConfig shared];
                [cfg reload];
                [NDRuntimeState publishWithConfig:cfg
                                          profile:[[NDRecordStore shared] currentProfile]
                                      currentName:[[NDRecordStore shared] currentRecordName]];
            }
        };
        publishRuntime();

        // Ensure NewDevice owns target-app inject (Venmo etc.) — exclude from amg.plist.
        @try {
            [[NDConfig shared] reload];
            NSArray *targets = [NDConfig shared].targetApps ?: @[];
            if (!targets.count) targets = @[ @"net.kortina.labs.Venmo" ];
            [[NDAppDataManager shared] syncInjectFilterWithTargetApps:targets];
        } @catch (__unused NSException *e) {
            NSLog(@"[newdeviced] syncInjectFilter failed: %@", e);
        }

        // If App holds the port, keep waiting and rebind when it exits so API
        // survives App death (scripts / AMG keep working via daemon).
        for (;;) {
            NSError *error = nil;
            if ([[NDHTTPServer shared] startWithPort:(uint16_t)NDHTTPPort error:&error]) {
                NSLog(@"[newdeviced] listening on http://127.0.0.1:%ld/cmd", (long)NDHTTPPort);
                [[NSRunLoop currentRunLoop] run];
                // runLoop ended unexpectedly — try to rebind
                [[NDHTTPServer shared] stop];
                NSLog(@"[newdeviced] runloop ended, will rebind");
                continue;
            }
            BOOL inUse = (error.code == EADDRINUSE) || [error.localizedDescription containsString:@"bind"];
            if (inUse) {
                NSLog(@"[newdeviced] port in use (App may be serving), retry in 3s");
                publishRuntime();
                sleep(3);
                continue;
            }
            NSLog(@"[newdeviced] failed to start: %@", error);
            return 1;
        }
    }
    return 0;
}
