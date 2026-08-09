#import <Foundation/Foundation.h>
#import "NDHTTPServer.h"
#import "NDPaths.h"
#import "NDRecordStore.h"
#import <errno.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [NDPaths ensureDirectories];
        [[NDRecordStore shared] currentRecordName];

        NSError *error = nil;
        if (![[NDHTTPServer shared] startWithPort:(uint16_t)NDHTTPPort error:&error]) {
            // If App already holds the port, exit quietly — App is serving API.
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
