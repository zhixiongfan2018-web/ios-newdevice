#import "NDAPIClient.h"
#import "NDPaths.h"
#import "NDOperationService.h"
#import "NDHTTPServer.h"

@implementation NDAPIClient

+ (instancetype)shared {
    static NDAPIClient *c;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ c = [NDAPIClient new]; });
    return c;
}

- (void)call:(NSString *)fun completion:(void (^)(BOOL, NSString * _Nullable, NSError * _Nullable))completion {
    [self call:fun query:nil completion:completion];
}

- (void)pollResultWithTimeout:(NSTimeInterval)timeout completion:(void (^)(BOOL ok, NSString * _Nullable body, NSError * _Nullable error))completion {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
            NSString *raw = [NSString stringWithContentsOfFile:[NDPaths resultFilePath] encoding:NSUTF8StringEncoding error:nil];
            raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([raw isEqualToString:@"1"]) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, @"1", nil); });
                return;
            }
            if ([raw isEqualToString:@"0"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, @"0", [NSError errorWithDomain:@"NDAPI" code:0 userInfo:@{NSLocalizedDescriptionKey: @"执行失败"}]);
                });
                return;
            }
            [NSThread sleepForTimeInterval:0.35];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, nil, [NSError errorWithDomain:@"NDAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"等待结果超时"}]);
        });
    });
}

- (void)call:(NSString *)fun query:(NSDictionary<NSString *,NSString *> *)query completion:(void (^)(BOOL, NSString * _Nullable, NSError * _Nullable))completion {
    NSError *ensureErr = nil;
    if (![[NDHTTPServer shared] ensureRunning:&ensureErr]) {
        // Fallback: run in-process for both sync and async funs when no listener is available.
        [[NDOperationService shared] runAsync:fun query:query ?: @{} completion:^(NSString *body, NSInteger httpCode) {
            if ([NDOperationService isAsyncAckFun:fun]) {
                [self pollResultWithTimeout:120 completion:completion];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(httpCode == 200, body, httpCode == 200 ? nil : ensureErr);
                });
            }
        }];
        return;
    }

    NSURLComponents *comp = [NSURLComponents new];
    comp.scheme = @"http";
    comp.host = NDHTTPHost;
    comp.port = @(NDHTTPPort);
    comp.path = @"/cmd";
    NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"fun" value:fun]];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:key value:obj]];
    }];
    comp.queryItems = items;

    NSURLRequest *req = [NSURLRequest requestWithURL:comp.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
        BOOL ok = !error && http.statusCode == 200;
        if (!ok) {
            // Last resort in-process
            [[NDOperationService shared] runAsync:fun query:query ?: @{} completion:^(NSString *b, NSInteger code) {
                if ([NDOperationService isAsyncAckFun:fun]) {
                    [self pollResultWithTimeout:120 completion:completion];
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(code == 200, b, code == 200 ? nil : error);
                    });
                }
            }];
            return;
        }
        if ([NDOperationService isAsyncAckFun:fun]) {
            [self pollResultWithTimeout:120 completion:completion];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, body, nil);
        });
    }] resume];
}

@end
