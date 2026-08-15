#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ExportPickerViewController : UITableViewController
@property (nonatomic, copy, nullable) void (^onExport)(NSArray<NSString *> *names);
@end

NS_ASSUME_NONNULL_END
