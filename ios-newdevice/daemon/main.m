#import <Foundation/Foundation.h>
#import "NDHTTPServer.h"
#import "NDPaths.h"
#import "NDRecordStore.h"
#import <errno.h>
#import <unistd.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [NDPaths ensureDirectories];
        [[NDRecordStore shared] currentRecordName];

        // Prefer staying alive: if App currently owns :8080, wait and retry so
        // KeepAlive does not spawn a tight exit/relaunch storm.
        for (;;) {
            NSError *error = nil;
            if ([[NDHTTPServer shared] startWithPort:(uint16_t)NDHTTPPort error:&error]) {
                NSLog(@"[newdeviced] listening on http://127.0.0.1:%ld/cmd", (long)NDHTTPPort);
                [[NSRunLoop currentRunLoop] run];
                // Runloop ended (listener stopped). Retry bind after a short delay.
                [[NDHTTPServer shared] stop];
                sleep(2);
                continue;
            }

            BOOL portBusy = (error.code == EADDRINUSE) ||
                            [error.localizedDescription.lowercaseString containsString:@"bind"] ||
                            [error.localizedDescription containsString:@"in use"];
            if (portBusy) {
                NSLog(@"[newdeviced] port in use (App may be serving API); retry in 5s");
                sleep(5);
                continue;
            }

            NSLog(@"[newdeviced] failed to start: %@", error);
            return 1;
        }
    }
    return 0;
}
