#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDOperationService : NSObject
+ (instancetype)shared;
/// Long-running funs that should ACK HTTP immediately (AMG-compatible).
+ (BOOL)isAsyncAckFun:(NSString *)fun;
/// Claim the single global async job slot (result file). Returns NO if busy.
- (BOOL)tryBeginAsyncJob;
- (void)endAsyncJob;
- (BOOL)isAsyncBusy;
/// @param preclaimed YES when caller already succeeded at tryBeginAsyncJob (HTTP ACK path).
- (void)runAsync:(NSString *)fun query:(NSDictionary<NSString *, NSString *> *)query completion:(void (^)(NSString * _Nullable body, NSInteger httpCode))completion;
- (void)runAsync:(NSString *)fun query:(NSDictionary<NSString *, NSString *> *)query preclaimed:(BOOL)preclaimed completion:(void (^)(NSString * _Nullable body, NSInteger httpCode))completion;
/// Close 改机: backup current env, wipe target sandboxes, publish 本机. Remembers last session.
- (void)suspendSpoofAndClean;
/// Open 改机: restore last session identity + holographic sandboxes.
- (void)resumeSpoofFromLastSession;
@end

NS_ASSUME_NONNULL_END
