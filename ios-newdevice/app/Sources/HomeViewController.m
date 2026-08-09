#import "HomeViewController.h"
#import "NDAPIClient.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import "NDAirplane.h"
#import "NDHTTPServer.h"
#import "NDPaths.h"
#import "ProbeViewController.h"
#import "ProfileDetailViewController.h"

@interface HomeViewController ()
@property (nonatomic, strong) UILabel *recordLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *ipLabel;
@property (nonatomic, strong) UILabel *apiLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSString *lastIP;
@property (nonatomic, assign) BOOL busy;
@end

@implementation HomeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"NewDevice";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"探测" style:UIBarButtonItemStylePlain target:self action:@selector(openProbe)];

    self.recordLabel = [UILabel new];
    self.recordLabel.font = [UIFont boldSystemFontOfSize:22];
    self.recordLabel.textAlignment = NSTextAlignmentCenter;
    self.recordLabel.numberOfLines = 0;

    self.summaryLabel = [UILabel new];
    self.summaryLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.summaryLabel.numberOfLines = 0;
    self.summaryLabel.textColor = [UIColor secondaryLabelColor];

    self.ipLabel = [UILabel new];
    self.ipLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.ipLabel.textAlignment = NSTextAlignmentCenter;
    self.ipLabel.text = @"IP: --";

    self.apiLabel = [UILabel new];
    self.apiLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    self.apiLabel.textAlignment = NSTextAlignmentCenter;
    self.apiLabel.numberOfLines = 0;
    self.apiLabel.text = @"API: 检测中…";

    UIButton *newBtn = [self actionButton:@"一键新机" color:[UIColor systemBlueColor] action:@selector(newDevice)];
    UIButton *origBtn = [self actionButton:@"原始机器" color:[UIColor systemGrayColor] action:@selector(original)];
    UIButton *nextBtn = [self actionButton:@"下一条" color:[UIColor systemTealColor] action:@selector(nextRecord)];
    UIButton *detailBtn = [self actionButton:@"查看参数" color:[UIColor systemIndigoColor] action:@selector(openDetail)];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.hidesWhenStopped = YES;

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[newBtn, origBtn, nextBtn, detailBtn]];
    actions.axis = UILayoutConstraintAxisVertical;
    actions.spacing = 12;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.recordLabel, self.apiLabel, self.ipLabel, self.summaryLabel, actions, self.spinner]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
    ]];
}

- (UIButton *)actionButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = color;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:48].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    [self refreshAPIStatus];
    [self refreshIP:NO];
}

- (void)refreshAPIStatus {
    NSError *err = nil;
    BOOL ok = [[NDHTTPServer shared] ensureRunning:&err];
    if (ok || [NDHTTPServer shared].running) {
        self.apiLabel.text = @"API: http://127.0.0.1:8080/cmd 已监听\n请在手机本机访问（先打开本 App）";
        self.apiLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.apiLabel.text = [NSString stringWithFormat:@"API: 未启动\n%@", err.localizedDescription ?: @"请重启 App"];
        self.apiLabel.textColor = [UIColor systemRedColor];
    }
}

- (void)refresh {
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    self.recordLabel.text = [NSString stringWithFormat:@"当前记录\n%@", p.name ?: @"--"];
    self.summaryLabel.text = [NSString stringWithFormat:
                              @"Model: %@\nSystem: %@\nIDFA: %@\nIDFV: %@\nSerial: %@\nUDID: %@\nWiFi: %@\nCarrier: %@ (%@/%@)\nGPS: %.5f, %.5f",
                              p.Model, p.SystemVer, p.IDFA, p.IDFV, p.Serial, p.UDID, p.WiFiMAC, p.Carrier, p.MCC, p.MNC, p.Latitude, p.Longitude];
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    if (busy) [self.spinner startAnimating];
    else [self.spinner stopAnimating];
    self.view.userInteractionEnabled = !busy;
}

- (void)run:(NSString *)fun {
    if (self.busy) return;
    self.busy = YES;
    NSString *prevIP = self.lastIP;
    [[NDAPIClient shared] call:fun completion:^(BOOL ok, NSString *body, NSError *error) {
        self.busy = NO;
        [self refresh];
        [self refreshIP:YES expectedChangeFrom:prevIP];
        if (!ok) {
            [self alert:error.localizedDescription ?: @"执行失败（请确认 newdeviced 已运行）"];
        }
    }];
}

- (void)newDevice { [self run:@"newRecord"]; }
- (void)original { [self run:@"originRecord"]; }
- (void)nextRecord { [self run:@"nextRecord"]; }

- (void)refreshIP:(BOOL)compare {
    [self refreshIP:compare expectedChangeFrom:self.lastIP];
}

- (void)refreshIP:(BOOL)compare expectedChangeFrom:(NSString *)prev {
    [NDAirplane fetchPublicIPWithCompletion:^(NSString *ip, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ip) {
                self.ipLabel.text = @"IP: 获取失败";
                self.ipLabel.textColor = [UIColor systemOrangeColor];
                return;
            }
            self.ipLabel.text = [NSString stringWithFormat:@"IP: %@", ip];
            if (compare && prev.length && [prev isEqualToString:ip]) {
                self.ipLabel.textColor = [UIColor systemRedColor];
            } else {
                self.ipLabel.textColor = [UIColor labelColor];
            }
            self.lastIP = ip;
        });
    }];
}

- (void)openProbe {
    [self.navigationController pushViewController:[ProbeViewController new] animated:YES];
}

- (void)openDetail {
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    if (!p) return;
    ProfileDetailViewController *vc = [[ProfileDetailViewController alloc] initWithProfile:p];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"提示" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
