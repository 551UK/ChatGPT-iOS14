#pragma mark - CGChatViewController.h
@interface CGChatViewController : UIViewController
- (void)reloadConversation;
@end

#pragma mark - CGSidebarViewController.h
@class CGChatViewController;
@interface CGSidebarViewController : UITableViewController
@property (nonatomic, weak) CGChatViewController *chatController;
@end

#pragma mark - CGSidebarViewController.m

@implementation CGSidebarViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"ChatGPT"; self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)]; }
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : CGStore.shared.conversations.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? nil : @"Chats"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.section == 0) {
        NSArray *names = @[@"New chat", @"ChatGPT Web", @"Settings"]; NSArray *icons = @[@"square.and.pencil", @"globe", @"gearshape"];
        cell.textLabel.text = names[ip.row]; cell.imageView.image = [UIImage systemImageNamed:icons[ip.row]]; cell.accessoryType = ip.row ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    } else {
        CGConversation *c = CGStore.shared.conversations[ip.row]; cell.textLabel.text = c.title; cell.detailTextLabel.text = [c.identifier isEqualToString:CGStore.shared.currentConversationID] ? @"Current" : nil; cell.imageView.image = [UIImage systemImageNamed:@"message"];
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 0) { [CGStore.shared newConversation]; [self.chatController reloadConversation]; [self done]; }
    else if (ip.section == 0 && ip.row == 1) { [self.navigationController pushViewController:[CGWebViewController new] animated:YES]; }
    else if (ip.section == 0 && ip.row == 2) { CGSettingsViewController *s = [CGSettingsViewController new]; UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:s]; [self presentViewController:n animated:YES completion:nil]; }
    else if (ip.section == 1) { CGConversation *c = CGStore.shared.conversations[ip.row]; CGStore.shared.currentConversationID = c.identifier; [CGStore.shared save]; [self.chatController reloadConversation]; [self done]; }
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete) { CGConversation *c = CGStore.shared.conversations[ip.row]; [CGStore.shared deleteConversation:c]; [tableView reloadData]; [self.chatController reloadConversation]; }
}
@end

#pragma mark - CGChatViewController.m

@interface CGChatViewController () <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIView *composer;
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UIButton *plusButton;
@property (nonatomic, strong) UIButton *micButton;
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UILabel *attachmentLabel;
@property (nonatomic, strong) NSMutableArray<CGAttachment *> *pendingAttachments;
@property (nonatomic, strong) CGAPIClient *api;
@property (nonatomic, assign) BOOL generating;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *speechRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask *speechTask;
@property (nonatomic, strong) AVSpeechSynthesizer *speaker;
@end

@implementation CGChatViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemBackgroundColor; self.pendingAttachments = [NSMutableArray array]; self.speaker = [AVSpeechSynthesizer new];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.horizontal.3"] style:UIBarButtonItemStylePlain target:self action:@selector(openSidebar)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.pencil"] style:UIBarButtonItemStylePlain target:self action:@selector(newChat)];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain]; self.table.translatesAutoresizingMaskIntoConstraints = NO; self.table.dataSource = self; self.table.delegate = self; self.table.separatorStyle = UITableViewCellSeparatorStyleNone; self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive; self.table.backgroundColor = UIColor.systemBackgroundColor; [self.table registerClass:CGMessageCell.class forCellReuseIdentifier:@"Message"];
    [self.view addSubview:self.table];

    self.composer = [UIView new]; self.composer.translatesAutoresizingMaskIntoConstraints = NO; self.composer.backgroundColor = UIColor.systemBackgroundColor; [self.view addSubview:self.composer];
    UIView *box = [UIView new]; box.translatesAutoresizingMaskIntoConstraints = NO; box.backgroundColor = UIColor.secondarySystemBackgroundColor; box.layer.cornerRadius = 22; box.layer.cornerCurve = kCACornerCurveContinuous; [self.composer addSubview:box];
    self.plusButton = [self button:@"plus" action:@selector(attachTapped)];
    self.micButton = [self button:@"mic" action:@selector(micTapped)];
    self.voiceButton = [self button:@"waveform.circle.fill" action:@selector(voiceTapped)];
    self.sendButton = [self button:@"arrow.up.circle.fill" action:@selector(sendTapped)];
    [box addSubview:self.plusButton]; [box addSubview:self.micButton]; [box addSubview:self.voiceButton]; [box addSubview:self.sendButton];
    self.input = [UITextView new]; self.input.translatesAutoresizingMaskIntoConstraints = NO; self.input.backgroundColor = UIColor.clearColor; self.input.font = [UIFont systemFontOfSize:16]; self.input.delegate = self; self.input.scrollEnabled = YES; self.input.textContainerInset = UIEdgeInsetsMake(9, 2, 8, 2); [box addSubview:self.input];
    self.attachmentLabel = [UILabel new]; self.attachmentLabel.translatesAutoresizingMaskIntoConstraints = NO; self.attachmentLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; self.attachmentLabel.textColor = UIColor.secondaryLabelColor; self.attachmentLabel.numberOfLines = 2; self.attachmentLabel.hidden = YES; [self.composer addSubview:self.attachmentLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor], [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [self.table.bottomAnchor constraintEqualToAnchor:self.composer.topAnchor],
        [self.composer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.composer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [self.composer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.attachmentLabel.topAnchor constraintEqualToAnchor:self.composer.topAnchor constant:4], [self.attachmentLabel.leadingAnchor constraintEqualToAnchor:self.composer.leadingAnchor constant:18], [self.attachmentLabel.trailingAnchor constraintEqualToAnchor:self.composer.trailingAnchor constant:-18],
        [box.topAnchor constraintEqualToAnchor:self.attachmentLabel.bottomAnchor constant:4], [box.leadingAnchor constraintEqualToAnchor:self.composer.leadingAnchor constant:10], [box.trailingAnchor constraintEqualToAnchor:self.composer.trailingAnchor constant:-10], [box.bottomAnchor constraintEqualToAnchor:self.composer.bottomAnchor constant:-7], [box.heightAnchor constraintGreaterThanOrEqualToConstant:46],
        [self.plusButton.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:5], [self.plusButton.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-4], [self.plusButton.widthAnchor constraintEqualToConstant:38], [self.plusButton.heightAnchor constraintEqualToConstant:38],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-5], [self.sendButton.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-4], [self.sendButton.widthAnchor constraintEqualToConstant:38], [self.sendButton.heightAnchor constraintEqualToConstant:38],
        [self.voiceButton.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-1], [self.voiceButton.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-4], [self.voiceButton.widthAnchor constraintEqualToConstant:34], [self.voiceButton.heightAnchor constraintEqualToConstant:38],
        [self.micButton.trailingAnchor constraintEqualToAnchor:self.voiceButton.leadingAnchor constant:-1], [self.micButton.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-4], [self.micButton.widthAnchor constraintEqualToConstant:34], [self.micButton.heightAnchor constraintEqualToConstant:38],
        [self.input.leadingAnchor constraintEqualToAnchor:self.plusButton.trailingAnchor constant:2], [self.input.trailingAnchor constraintEqualToAnchor:self.micButton.leadingAnchor constant:-2], [self.input.topAnchor constraintEqualToAnchor:box.topAnchor constant:2], [self.input.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-2], [self.input.heightAnchor constraintLessThanOrEqualToConstant:125]
    ]];
    [self reloadConversation];
}
- (UIButton *)button:(NSString *)symbol action:(SEL)action { UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; b.translatesAutoresizingMaskIntoConstraints = NO; [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal]; b.tintColor = UIColor.labelColor; [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return b; }
- (CGConversation *)conversation { return CGStore.shared.currentConversation; }
