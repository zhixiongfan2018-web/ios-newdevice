#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SystemVersionPickerViewController : UITableViewController
- (instancetype)initWithCurrentVersion:(nullable NSString *)current;
@property (nonatomic, copy, nullable) void (^onPick)(NSString *systemVer, NSString *build);
@end

NS_ASSUME_NONNULL_END
