#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDOperationService : NSObject
+ (instancetype)shared;
/// Long-running funs that should ACK HTTP immediately (AMG-compatible).
+ (BOOL)isAsyncAckFun:(NSString *)fun;
- (void)runAsync:(NSString *)fun query:(NSDictionary<NSString *, NSString *> *)query completion:(void (^)(NSString * _Nullable body, NSInteger httpCode))completion;
@end

NS_ASSUME_NONNULL_END
