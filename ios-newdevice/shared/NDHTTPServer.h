#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDHTTPServer : NSObject
@property (nonatomic, assign, readonly) BOOL running;
@property (nonatomic, assign, readonly) uint16_t port;

+ (instancetype)shared;
- (BOOL)startWithPort:(uint16_t)port error:(NSError * _Nullable * _Nullable)error;
- (BOOL)ensureRunning:(NSError * _Nullable * _Nullable)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
