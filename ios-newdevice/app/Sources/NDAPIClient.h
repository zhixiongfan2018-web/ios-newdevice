#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDAPIClient : NSObject
+ (instancetype)shared;
- (void)call:(NSString *)fun query:(nullable NSDictionary<NSString *, NSString *> *)query completion:(void (^)(BOOL ok, NSString * _Nullable body, NSError * _Nullable error))completion;
- (void)call:(NSString *)fun completion:(void (^)(BOOL ok, NSString * _Nullable body, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
