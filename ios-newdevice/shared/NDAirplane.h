#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDAirplane : NSObject
+ (BOOL)setAirplaneModeOn:(BOOL)on;
+ (BOOL)toggleAirplaneWithDelay:(NSTimeInterval)delay error:(NSError * _Nullable * _Nullable)error;
+ (void)fetchPublicIPWithCompletion:(void (^)(NSString * _Nullable ip, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
