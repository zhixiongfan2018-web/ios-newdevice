#import "RecordsViewController.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import "NDAPIClient.h"
#import "NDAMGImporter.h"
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
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"导入AMG" style:UIBarButtonItemStylePlain target:self action:@selector(importAMG)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(reload)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
}

- (void)importAMG {
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"导入 AMG"
                                                                   message:@"正在扫描 /var/mobile/AMG_tar 与 /var/mobile/AMG …\n大包可能需几分钟"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:nil];
    // In-process: avoids HTTP async 120s poll timeout on large holographic trees.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        BOOL ok = [NDAMGImporter importFromAMGTarDirectory:@"/var/mobile/AMG_tar" error:&err];
        NSString *detail = err.localizedDescription ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                [self reload];
                NSString *msg = ok
                    ? (detail.length
                           ? detail
                           : @"已写入记录列表（未自动切换）。密文 faker 请在记录目录旁放 faker_plaintext.plist。")
                    : (detail.length ? detail : @"导入失败，请确认 /var/mobile/AMG_tar 或 /var/mobile/AMG 有备份");
                UIAlertController *a = [UIAlertController alertControllerWithTitle:ok ? @"导入完成" : @"导入失败"
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            }];
        });
    });
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
