#pragma mark - CGMessageCell.h

@interface CGMessageCell : UITableViewCell
- (void)configureWithMessage:(CGMessage *)message;
@end

#pragma mark - CGMessageCell.m

@interface CGMessageCell ()
@property (nonatomic, strong) UIView *bubble;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSLayoutConstraint *bubbleLeading;
@property (nonatomic, strong) NSLayoutConstraint *bubbleTrailing;
@end

@implementation CGMessageCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;
        _bubble = [UIView new];
        _bubble.translatesAutoresizingMaskIntoConstraints = NO;
        _bubble.layer.cornerRadius = 18.0;
        _bubble.layer.cornerCurve = kCACornerCurveContinuous;
        [self.contentView addSubview:_bubble];
        _stack = [[UIStackView alloc] init];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 8;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_bubble addSubview:_stack];
        self.bubbleLeading = [_bubble.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12];
        self.bubbleTrailing = [_bubble.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12];
        [NSLayoutConstraint activateConstraints:@[
            [_bubble.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_bubble.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_bubble.widthAnchor constraintLessThanOrEqualToAnchor:self.contentView.widthAnchor multiplier:0.91],
            [_stack.topAnchor constraintEqualToAnchor:_bubble.topAnchor constant:11],
            [_stack.bottomAnchor constraintEqualToAnchor:_bubble.bottomAnchor constant:-11],
            [_stack.leadingAnchor constraintEqualToAnchor:_bubble.leadingAnchor constant:13],
            [_stack.trailingAnchor constraintEqualToAnchor:_bubble.trailingAnchor constant:-13]
        ]];
    }
    return self;
}
- (void)clearStack {
    for (UIView *v in self.stack.arrangedSubviews.copy) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}
- (void)prepareForReuse {
    [super prepareForReuse];
    [self clearStack];
}
- (UITextView *)textView:(NSString *)text color:(UIColor *)color font:(UIFont *)font {
    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.scrollEnabled = NO;
    tv.editable = NO;
    tv.selectable = YES;
    tv.backgroundColor = UIColor.clearColor;
    tv.textContainerInset = UIEdgeInsetsZero;
    tv.textContainer.lineFragmentPadding = 0;
    tv.dataDetectorTypes = UIDataDetectorTypeLink;
    tv.text = text ?: @"";
    tv.textColor = color;
    tv.font = font;
    tv.linkTextAttributes = @{NSForegroundColorAttributeName: UIColor.systemTealColor};
    return tv;
}
- (void)configureWithMessage:(CGMessage *)message {
    [self clearStack];
    BOOL user = [message.role isEqualToString:@"user"];
    self.bubble.backgroundColor = user ? UIColor.secondarySystemBackgroundColor : UIColor.clearColor;
    self.bubbleLeading.active = !user;
    self.bubbleTrailing.active = user;

    if (message.attachments.count) {
        for (CGAttachment *a in message.attachments) {
            if (a.image && a.data.length) {
                UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage imageWithData:a.data]];
                iv.contentMode = UIViewContentModeScaleAspectFill;
                iv.clipsToBounds = YES;
                iv.layer.cornerRadius = 12;
                iv.translatesAutoresizingMaskIntoConstraints = NO;
                [iv.heightAnchor constraintLessThanOrEqualToConstant:250].active = YES;
                [iv.heightAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
                [self.stack addArrangedSubview:iv];
            } else {
                UILabel *file = [UILabel new];
                file.numberOfLines = 1;
                file.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
                file.text = [NSString stringWithFormat:@"📄 %@", a.name ?: @"Attachment"];
                [self.stack addArrangedSubview:file];
            }
        }
    }
    if (message.text.length) {
        [self.stack addArrangedSubview:[self textView:message.text color:UIColor.labelColor font:[UIFont systemFontOfSize:16]]];
    }

    for (NSString *path in message.generatedImagePaths) {
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (!img) continue;
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = 12;
        iv.clipsToBounds = YES;
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        [iv.heightAnchor constraintEqualToConstant:260].active = YES;
        [self.stack addArrangedSubview:iv];
    }
    if (message.sources.count) {
        NSMutableString *s = [NSMutableString stringWithString:@"Sources\n"];
        NSInteger i = 1;
        for (NSDictionary *src in message.sources) {
            [s appendFormat:@"%ld. %@\n%@\n", (long)i++, src[@"title"] ?: @"Source", src[@"url"] ?: @""];
        }
        UITextView *tv = [self textView:s color:UIColor.secondaryLabelColor font:[UIFont systemFontOfSize:12]];
        [self.stack addArrangedSubview:tv];
    }
}
@end

#pragma mark - CGSettingsViewController.h
@interface CGSettingsViewController : UITableViewController
@end

#pragma mark - CGSettingsViewController.m

@interface CGSettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *keyField;
@end

@implementation CGSettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}
- (void)done {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : (section == 1 ? 2 : (section == 2 ? 3 : 3));
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"OpenAI API", @"Model", @"Tools", @"About this build"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Your API key is stored on this device. ChatGPT Plus and API billing are separate. Use ChatGPT Web from the sidebar for first-party account features.";
    if (section == 2) return @"Tools are sent through the OpenAI Responses API. Availability can depend on the model and API account.";
    if (section == 3) return @"Native chats are stored locally on this device. The Web fallback uses ChatGPT directly in a persistent iOS WebKit session.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    CGStore *s = CGStore.shared;
    if (ip.section == 0 && ip.row == 0) {
        cell.textLabel.text = @"API key";
        self.keyField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 36)];
        self.keyField.placeholder = @"sk-…";
        self.keyField.secureTextEntry = YES;
        self.keyField.textAlignment = NSTextAlignmentRight;
        self.keyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.keyField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.keyField.text = s.apiKey;
        self.keyField.delegate = self;
        [self.keyField addTarget:self action:@selector(keyChanged:) forControlEvents:UIControlEventEditingChanged];
        cell.accessoryView = self.keyField;
    } else if (ip.section == 0) {
        cell.textLabel.text = @"Test API key";
        cell.detailTextLabel.text = s.apiKey.length ? @"Tap to test" : @"Key required";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 1 && ip.row == 0) {
        cell.textLabel.text = @"Model";
        cell.detailTextLabel.text = s.model;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 1) {
        cell.textLabel.text = @"Reasoning";
        cell.detailTextLabel.text = [s.reasoningEffort capitalizedString];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 2) {
        NSArray *names = @[@"Web search", @"Image generation", @"Code interpreter"];
        cell.textLabel.text = names[ip.row];
        UISwitch *sw = [UISwitch new];
        sw.tag = ip.row;
        sw.on = ip.row == 0 ? s.webSearchEnabled : (ip.row == 1 ? s.imageGenerationEnabled : s.codeInterpreterEnabled);
        [sw addTarget:self action:@selector(toolChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSArray *names = @[@"Target", @"Package", @"Mode"];
        NSArray *values = @[@"iOS 14+ rootful", @"com.551.chatgpt14", @"Native + Web fallback"];
        cell.textLabel.text = names[ip.row];
        cell.detailTextLabel.text = values[ip.row];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)keyChanged:(UITextField *)f {
    [CGStore.shared setAPIKey:f.text ?: @""];
}
- (void)toolChanged:(UISwitch *)sw {
    if (sw.tag == 0) [CGStore.shared setWebSearchEnabled:sw.on];
    else if (sw.tag == 1) [CGStore.shared setImageGenerationEnabled:sw.on];
    else [CGStore.shared setCodeInterpreterEnabled:sw.on];
}
- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)testAPIKey {
    NSString *key = CGStore.shared.apiKey;
    if (!key.length) {
        [self showAlertTitle:@"API key required" message:@"Enter an OpenAI API key first."];
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.openai.com/v1/models"]];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 30;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [self showAlertTitle:@"Connection failed" message:error.localizedDescription ?: @"Could not contact OpenAI."];
                return;
            }
            NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (code >= 200 && code < 300) {
                [self showAlertTitle:@"API key works" message:@"OpenAI accepted the key. Native chat is ready."];
            } else {
                NSDictionary *obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSString *msg = obj[@"error"][@"message"] ?: [NSHTTPURLResponse localizedStringForStatusCode:code];
                [self showAlertTitle:@"API key failed" message:msg ?: @"OpenAI rejected the request."];
            }
        });
    }];
    [task resume];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    CGStore *s = CGStore.shared;
    if (ip.section == 0 && ip.row == 1) {
        [self testAPIKey];
    } else if (ip.section == 1 && ip.row == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Model" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *m in @[@"gpt-6-astra", @"gpt-5.6", @"gpt-5.6-terra", @"gpt-5.6-luna"]) {
            [a addAction:[UIAlertAction actionWithTitle:m style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){
                [s setModel:m];
                [self.tableView reloadData];
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        if (a.popoverPresentationController) a.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:ip];
        [self presentViewController:a animated:YES completion:nil];
    } else if (ip.section == 1 && ip.row == 1) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reasoning effort" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *r in @[@"none", @"low", @"medium", @"high", @"xhigh", @"max"]) {
            [a addAction:[UIAlertAction actionWithTitle:[r capitalizedString] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){
                [s setReasoningEffort:r];
                [self.tableView reloadData];
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        if (a.popoverPresentationController) a.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:ip];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

#pragma mark - CGWebViewController.h
@interface CGWebViewController : UIViewController
@end

#pragma mark - CGWebViewController.m

@interface CGWebViewController () <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *web;
@end

@implementation CGWebViewController
- (NSString *)compatibilityJavaScript {
    return @"(function(){"
            "if(!Object.hasOwn){Object.hasOwn=function(o,p){return Object.prototype.hasOwnProperty.call(o,p);};}"
            "if(!Array.prototype.at){Array.prototype.at=function(n){n=Math.trunc(n)||0;if(n<0)n+=this.length;return this[n];};}"
            "if(!String.prototype.replaceAll){String.prototype.replaceAll=function(a,b){return this.split(a).join(b);};}"
            "if(!Promise.any){Promise.any=function(ps){return new Promise(function(resolve,reject){var e=[],left=ps.length;if(!left)return reject(new Error('All promises were rejected'));ps.forEach(function(p,i){Promise.resolve(p).then(resolve,function(x){e[i]=x;if(--left===0)reject(e);});});});};}"
            "if(window.crypto&&!crypto.randomUUID){crypto.randomUUID=function(){return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,function(c){var r=Math.random()*16|0,v=c==='x'?r:(r&3|8);return v.toString(16);});};}"
            "})();";
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ChatGPT Web";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    cfg.preferences.javaScriptEnabled = YES;
    cfg.preferences.javaScriptCanOpenWindowsAutomatically = YES;
    WKUserContentController *content = [WKUserContentController new];
    WKUserScript *polyfills = [[WKUserScript alloc] initWithSource:[self compatibilityJavaScript] injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
    [content addUserScript:polyfills];
    cfg.userContentController = content;

    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    self.web.translatesAutoresizingMaskIntoConstraints = NO;
    self.web.navigationDelegate = self;
    self.web.UIDelegate = self;
    self.web.allowsBackForwardNavigationGestures = YES;
    self.web.customUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
    [self.view addSubview:self.web];
    [NSLayoutConstraint activateConstraints:@[
        [self.web.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://chatgpt.com/"]]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self.web action:@selector(reload)];
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!navigationAction.targetFrame || !navigationAction.targetFrame.isMainFrame) {
        [webView loadRequest:navigationAction.request];
    }
    return nil;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (!scheme.length || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"about"] || [scheme isEqualToString:@"data"] || [scheme isEqualToString:@"blob"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}
@end
