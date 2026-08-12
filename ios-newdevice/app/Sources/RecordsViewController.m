#import "RecordsViewController.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import "NDAPIClient.h"
#import "NDTheme.h"
#import "ProfileDetailViewController.h"

@interface RecordsViewController ()
@property (nonatomic, copy) NSArray<NSString *> *names;
@end

@implementation RecordsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"记录";
    self.view.backgroundColor = [NDTheme canvas];
    self.tableView.backgroundColor = [NDTheme canvas];
    self.tableView.separatorColor = [NDTheme hairline];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    UIBarButtonItem *reload = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(reload)];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showMore)];
    self.navigationItem.rightBarButtonItems = @[reload, more];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"导入" style:UIBarButtonItemStylePlain target:self action:@selector(importProfile)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
}

- (void)showMore {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"记录" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从 AMG 导入 (/var/mobile/AMG)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self importFromAMG];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导出当前记录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self exportCurrent];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)importFromAMG {
    NSError *err = nil;
    NSUInteger n = [[NDRecordStore shared] importAMGRecordsFromDirectory:@"/var/mobile/AMG" error:&err];
    NSString *msg = n
        ? [NSString stringWithFormat:@"已导入 %lu 条记录（含 faker 身份 / 全息 App / AppGroup / selectApp）。\n若 faker.plist 为加密导出，会生成随机身份并仍迁移 App 数据；详见记录目录 amg-import-note.txt。", (unsigned long)n]
        : (err.localizedDescription ?: @"未找到可导入的 AMG 记录");
    UIAlertController *a = [UIAlertController alertControllerWithTitle:n ? @"导入完成" : @"导入结果" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
    [self reload];
}

- (void)exportCurrent {
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    if (!p) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", p.name ?: @"record"]];
    NSError *err = nil;
    if (![p writeToPath:path error:&err]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导出失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    [self presentViewController:av animated:YES completion:nil];
}

- (void)importProfile {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"导入" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从 AMG 目录导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self importFromAMG];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从 plist 路径导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self importFromPathPrompt];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)importFromPathPrompt {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导入记录" message:@"支持 NewDevice / AMG 参数 plist（自动映射 SerialNum、MAC 等别名）" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"/var/mobile/AMG/某记录/profile.plist";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *path = a.textFields.firstObject.text ?: @"";
        NSError *e = nil;
        NDDeviceProfile *p = [[NDRecordStore shared] importProfileAtPath:path preferredName:nil error:&e];
        if (!p) {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"导入失败" message:e.localizedDescription ?: @"无法读取 plist" preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:err animated:YES completion:nil];
            return;
        }
        [self reload];
        UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已导入" message:p.name preferredStyle:UIAlertControllerStyleAlert];
        [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ok animated:YES completion:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.names = [[NDRecordStore shared] allRecordNames];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.names.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *name = self.names[indexPath.row];
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
    BOOL current = [name isEqualToString:[[NDRecordStore shared] currentRecordName]];

    cell.textLabel.font = [NDTheme headlineFont];
    cell.textLabel.text = name;
    cell.detailTextLabel.font = [NDTheme captionFont];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 2;
    NSString *state = p.enabled ? @"" : @" · 已禁用";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · iOS %@%@", p.Model ?: @"-", p.SystemVer ?: @"-", state];

    if (current) {
        cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        cell.imageView.tintColor = [NDTheme accent];
        cell.textLabel.textColor = [NDTheme accent];
    } else {
        cell.imageView.image = [UIImage systemImageNamed:@"circle"];
        cell.imageView.tintColor = [UIColor tertiaryLabelColor];
        cell.textLabel.textColor = [UIColor labelColor];
    }
    cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
    cell.tintColor = [NDTheme accent];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = self.names[indexPath.row];
    [[NDAPIClient shared] call:@"setRecord" query:@{@"recordName": name} completion:^(BOOL ok, NSString *body, NSError *error) {
        [self reload];
        if (!ok) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"切换失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        }
    }];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:self.names[indexPath.row]];
    [self.navigationController pushViewController:[[ProfileDetailViewController alloc] initWithProfile:p] animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = self.names[indexPath.row];
    if ([name isEqualToString:@"原始机器"]) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        [[NDAPIClient shared] call:@"deleteRecord" query:@{@"recordName": name} completion:^(BOOL ok, NSString *body, NSError *error) {
            [self reload];
            completionHandler(YES);
        }];
    }];
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
    UIContextualAction *toggle = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:p.enabled ? @"禁用" : @"启用" handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        NSString *fun = p.enabled ? @"disableRecord" : @"enableRecord";
        [[NDAPIClient shared] call:fun query:@{@"recordName": name} completion:^(BOOL ok, NSString *body, NSError *error) {
            [self reload];
            completionHandler(YES);
        }];
    }];
    toggle.backgroundColor = [NDTheme accent];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, toggle]];
}

@end
