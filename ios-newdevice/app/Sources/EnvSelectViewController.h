#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Single-select environment picker for 一键新机.
/// Passes nil name when user chooses「新建环境」; otherwise the selected record name.
@interface EnvSelectViewController : UITableViewController
@property (nonatomic, copy, nullable) void (^onPick)(NSString * _Nullable recordName);
@end

NS_ASSUME_NONNULL_END
