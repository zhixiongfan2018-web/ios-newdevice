#import "AppsViewController.h"
#import "NDConfig.h"
#import "NDTheme.h"
#import <objc/message.h>
#import <objc/runtime.h>

@interface NDAppItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleId;
@end
@implementation NDAppItem
@end

@interface AppsViewController ()
@property (nonatomic, copy) NSArray<NDAppItem *> *apps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@end

@implementation AppsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"目标应用";
    self.view.backgroundColor = [NDTheme canvas];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    [[NDConfig shared] reload];
    self.selected = [NSMutableSet setWithArray:[NDConfig shared].targetApps ?: @[]];
    [self loadApps];
    [self updateTitleBadge];
}

- (void)updateTitleBadge {
    self.navigationItem.prompt = [NSString stringWithFormat:@"已选 %lu 个 · 一键新机将清理/备份这些 App", (unsigned long)self.selected.count];
}

- (void)loadApps {
    NSMutableArray *items = [NSMutableArray array];
    Class LSApplicationWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = nil;
    if (LSApplicationWorkspace) {
        SEL sel = NSSelectorFromString(@"defaultWorkspace");
        if ([LSApplicationWorkspace respondsToSelector:sel]) {
            workspace = ((id (*)(id, SEL))objc_msgSend)(LSApplicationWorkspace, sel);
        }
    }
    NSArray *proxies = nil;
    if (workspace) {
        SEL sel = NSSelectorFromString(@"allInstalledApplications");
        if ([workspace respondsToSelector:sel]) {
            proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, sel);
        }
    }
    for (id proxy in proxies) {
        NSString *bid = nil;
        NSString *name = nil;
        SEL idSel = NSSelectorFromString(@"applicationIdentifier");
        SEL nameSel = NSSelectorFromString(@"localizedName");
        if ([proxy respondsToSelector:idSel]) {
            bid = ((id (*)(id, SEL))objc_msgSend)(proxy, idSel);
        }
        if ([proxy respondsToSelector:nameSel]) {
            name = ((id (*)(id, SEL))objc_msgSend)(proxy, nameSel);
        }
        if (!bid.length || [bid hasPrefix:@"com.apple."]) continue;
        if ([bid isEqualToString:@"com.local.newdevice"]) continue;
        NDAppItem *item = [NDAppItem new];
        item.bundleId = bid;
        item.name = name.length ? name : bid;
        [items addObject:item];
    }
    [items sortUsingComparator:^NSComparisonResult(NDAppItem *a, NDAppItem *b) {
        return [a.name localizedCompare:b.name];
    }];
    self.apps = items;
    if (items.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"未枚举到应用"
                                                                   message:@"当前环境无法使用 LSApplicationWorkspace。仍可手动编辑 config.plist 的 targetApps。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentViewController:a animated:YES completion:nil];
        });
    }
    [self.tableView reloadData];
}

- (void)save {
    [NDConfig shared].targetApps = self.selected.allObjects;
    [[NDConfig shared] save];
    [self updateTitleBadge];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已保存" message:[NSString stringWithFormat:@"已选择 %lu 个应用", (unsigned long)self.selected.count] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"勾选后点右上角保存。NewDevice 自身始终参与伪装探测。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NDAppItem *item = self.apps[indexPath.row];
    BOOL on = [self.selected containsObject:item.bundleId];
    cell.textLabel.font = [NDTheme headlineFont];
    cell.textLabel.text = item.name;
    cell.detailTextLabel.font = [NDTheme monoFont:11];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = item.bundleId;
    cell.imageView.image = [UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle"];
    cell.imageView.tintColor = on ? [NDTheme accent] : [UIColor tertiaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NDAppItem *item = self.apps[indexPath.row];
    if ([self.selected containsObject:item.bundleId]) [self.selected removeObject:item.bundleId];
    else [self.selected addObject:item.bundleId];
    [self updateTitleBadge];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
