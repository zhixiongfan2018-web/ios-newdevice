#import <Foundation/Foundation.h>
#import "NDHTTPServer.h"
#import "NDPaths.h"
#import "NDRecordStore.h"
#import "NDRuntimeState.h"
#import "NDConfig.h"
#import "NDAppDataManager.h"
#import <errno.h>
#import <string.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [NDPaths ensureDirectories];

        // One-shot: clear Venmo keychain with daemon entitlements (App UI cannot).
        if (argc >= 2 && argv[1] && strcmp(argv[1], "clear-venmo-kc") == 0) {
            NSString *body = [[NDAppDataManager shared] clearVenmoKeychainAllKnownGroups] ?: @"";
            [body writeToFile:@"/var/mobile/Media/NewDevice/last-keychain-clear.txt"
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fprintf(stdout, "%s\n", body.UTF8String ?: "");
            return 0;
        }

        // Publish world-readable runtime snapshot at boot so sandboxed target apps
        // can spoof even before the NewDevice UI is opened.
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

        NSError *error = nil;
        if (![[NDHTTPServer shared] startWithPort:(uint16_t)NDHTTPPort error:&error]) {
            // If App already holds the port, exit quietly — App is serving API.
            // Runtime snapshot was already published above.
            if (error.code == EADDRINUSE || [error.localizedDescription containsString:@"bind"]) {
                NSLog(@"[newdeviced] port in use, exit (App may be serving API)");
                return 0;
            }
            NSLog(@"[newdeviced] failed to start: %@", error);
            return 1;
        }
        NSLog(@"[newdeviced] listening on http://127.0.0.1:%ld/cmd", (long)NDHTTPPort);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
