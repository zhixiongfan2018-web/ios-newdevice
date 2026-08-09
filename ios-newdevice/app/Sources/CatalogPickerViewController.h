#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, NDCatalogPickerKind) {
    NDCatalogPickerModels = 0,
    NDCatalogPickerSystems,
};

@interface CatalogPickerViewController : UITableViewController
- (instancetype)initWithKind:(NDCatalogPickerKind)kind;
@end
