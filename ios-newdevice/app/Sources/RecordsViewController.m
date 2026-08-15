#import "RecordsViewController.h"
#import "NDRecordStore.h"
#import "NDRecordStore+ImportExport.h"
#import "NDDeviceProfile.h"
#import "NDAPIClient.h"
#import "NDOperationService.h"
#import "NDAppDataManager.h"
#import "NDTheme.h"
#import "NDPaths.h"
#import "NDConfig.h"
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"从 AMG_tar 导入（官方导出路径）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self importFromAMG];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导出当前记录 (NewDevice)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self exportCurrent];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导出到 AMG_tar (明文 faker)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self exportAMGFolder];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"强制写入当前记录 App 沙盒" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [[NDRecordStore shared] currentRecordName] ?: @"";
        [[NDOperationService shared] runAsync:@"restoreHolo" query:@{@"recordName": name} completion:^(NSString *body, NSInteger code) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *al = [UIAlertController alertControllerWithTitle:(code == 200) ? @"写入结果" : @"写入失败"
                                                                             message:body.length ? body : @"无报告"
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:al animated:YES completion:nil];
            });
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)importFromAMG {
    NSString *dir = [NDRecordStore resolvedAMGImportPath];
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"正在导入" message:@"解压并写入 App 沙盒…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:^{
        [[NDOperationService shared] runAsync:@"importAMGRecords" query:@{@"dir": dir, @"keychain": @"1"} completion:^(NSString *body, NSInteger code) {
            // Import only stages data — restore separately to avoid jetsam/闪退.
            dispatch_async(dispatch_get_main_queue(), ^{
                [wait dismissViewControllerAnimated:YES completion:^{
                    NSUInteger okN = [NDRecordStore shared].lastImportSuccessCount;
                    NSUInteger failN = [NDRecordStore shared].lastImportFailCount;
                    NSUInteger skipN = [NDRecordStore shared].lastImportSkipCount;
                    NSString *msg = [NSString stringWithFormat:@"成功 %lu 个，失败 %lu 个",
                                     (unsigned long)okN, (unsigned long)failN];
                    if (skipN > 0) {
                        msg = [msg stringByAppendingFormat:@"，跳过 %lu 个", (unsigned long)skipN];
                    }
                    if (code != 200 && okN == 0 && skipN == 0 && body.length) {
                        msg = body;
                    }
                    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导入完成"
                                                                               message:msg
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:a animated:YES completion:nil];
                    [self reload];
                }];
            });
        }];
    }];
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

- (void)exportAMGFolder {
    NSError *err = nil;
    NSString *outDir = [NDRecordStore amgTarPath];
    NSUInteger n = [[NDRecordStore shared] exportAMGRecordsToDirectory:outDir slim:[NDConfig shared].slimExportStripMedia error:&err];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:n ? @"导出完成" : @"导出结果"
                                                               message:n ? [NSString stringWithFormat:@"已导出 %lu 条明文记录到\n%@", (unsigned long)n, outDir]
                                                                        : (err.localizedDescription ?: @"没有可导出的记录")
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *name = self.names[indexPath.row];
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
    BOOL current = [name isEqualToString:[[NDRecordStore shared] currentRecordName]];

    cell.textLabel.font = [NDTheme headlineFont];
    // Prefer remark as display title; keep folder name in subtitle when remarked.
    cell.textLabel.text = p.remark.length ? p.remark : name;
    cell.detailTextLabel.font = [NDTheme captionFont];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 3;
    NSString *state = p.enabled ? @"" : @" · 已禁用";
    NSString *appsHint = @"";
    if (![name isEqualToString:@"原始机器"]) {
        NSString *appsRoot = [[NDPaths recordDir:name] stringByAppendingPathComponent:@"apps"];
        NSArray *apps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsRoot error:nil] ?: @[];
        NSString *venmo = [appsRoot stringByAppendingPathComponent:@"net.kortina.labs.Venmo"];
        NSString *docsAkc = [[venmo stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"akc.plist"];
        BOOL akc = [[NSFileManager defaultManager] fileExistsAtPath:docsAkc]
            || [[NSFileManager defaultManager] fileExistsAtPath:[venmo stringByAppendingPathComponent:@"akc.plist"]];
        appsHint = [NSString stringWithFormat:@" · apps:%lu%@%@",
                    (unsigned long)apps.count, akc ? @" akc" : @"", apps.count ? @"" : @" (空)"];
    }
    NSString *meta = [NSString stringWithFormat:@"%@ · iOS %@%@%@", p.Model ?: @"-", p.SystemVer ?: @"-", state, appsHint];
    if (p.remark.length) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", name, meta];
    } else {
        cell.detailTextLabel.text = meta;
    }

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
    // In-process setRecord: restores App environment + avoids URL '+' encoding bugs
    [[NDOperationService shared] runAsync:@"setRecord" query:@{@"recordName": name} completion:^(NSString *body, NSInteger code) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reload];
            if (code != 200) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"切换失败"
                                                                           message:body.length ? body : @"无法切换"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            }
        });
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
    UIContextualAction *remark = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"备注" handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(YES);
        [self editRemarkForRecord:name];
    }];
    remark.backgroundColor = [UIColor systemOrangeColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, toggle, remark]];
}

- (void)editRemarkForRecord:(NSString *)name {
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
    if (!p) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"环境备注"
                                                               message:name
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = p.remark ?: @"";
        tf.placeholder = @"例如：主号 / 测试号";
        tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        p.remark = a.textFields.firstObject.text ?: @"";
        [[NDRecordStore shared] saveProfile:p error:nil];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
