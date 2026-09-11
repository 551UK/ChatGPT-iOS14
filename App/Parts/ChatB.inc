- (void)reloadConversation { self.title = self.conversation.title ?: @"ChatGPT"; [self.table reloadData]; dispatch_async(dispatch_get_main_queue(), ^{ [self scrollToBottom:NO]; }); }
- (void)newChat { if (self.generating) return; [CGStore.shared newConversation]; [self.pendingAttachments removeAllObjects]; [self updateAttachments]; self.input.text = @""; [self reloadConversation]; }
- (void)openSidebar { CGSidebarViewController *s = [CGSidebarViewController new]; s.chatController = self; UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:s]; [self presentViewController:n animated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.conversation.messages.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip { CGMessageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Message" forIndexPath:ip]; [cell configureWithMessage:self.conversation.messages[ip.row]]; return cell; }
- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath { return 90; }

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point API_AVAILABLE(ios(13.0)) {
    CGMessage *m = self.conversation.messages[ip.row]; __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        UIAction *copy = [UIAction actionWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__kindof UIAction * _Nonnull action){ UIPasteboard.generalPasteboard.string = m.text ?: @""; }];
        UIAction *share = [UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction * _Nonnull action){ [weakSelf shareMessage:m]; }];
        NSMutableArray *actions = [NSMutableArray arrayWithObjects:copy, share, nil];
        if ([m.role isEqualToString:@"assistant"] && m.text.length) {
            UIAction *speak = [UIAction actionWithTitle:@"Read aloud" image:[UIImage systemImageNamed:@"speaker.wave.2"] identifier:nil handler:^(__kindof UIAction * _Nonnull action){ [weakSelf readAloud:m.text]; }]; [actions addObject:speak];
            if (ip.row == weakSelf.conversation.messages.count - 1) { UIAction *regen = [UIAction actionWithTitle:@"Regenerate" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(__kindof UIAction * _Nonnull action){ [weakSelf regenerate]; }]; [actions addObject:regen]; }
        }
        return [UIMenu menuWithTitle:@"" children:actions];
    }];
}
- (void)shareMessage:(CGMessage *)m { if (!m.text.length) return; UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[m.text] applicationActivities:nil]; if (a.popoverPresentationController) a.popoverPresentationController.sourceView = self.view; [self presentViewController:a animated:YES completion:nil]; }
- (void)readAloud:(NSString *)text { [self.speaker stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text]; u.rate = 0.50; [self.speaker speakUtterance:u]; }

- (void)sendTapped { if (self.generating) { [self.api cancel]; self.generating = NO; [self updateSendButton]; [CGStore.shared save]; return; } [self sendCurrentText]; }
- (void)sendCurrentText {
    NSString *key = CGStore.shared.apiKey; if (!key.length) { [self showSettingsRequired]; return; }
    NSString *text = [self.input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (!text.length && self.pendingAttachments.count == 0) return;
    CGMessage *user = [CGMessage new]; user.role = @"user"; user.text = text ?: @""; [user.attachments addObjectsFromArray:self.pendingAttachments]; [self.conversation.messages addObject:user];
    if ([self.conversation.title isEqualToString:@"New chat"] && text.length) { self.conversation.title = text.length > 42 ? [[text substringToIndex:42] stringByAppendingString:@"…"] : text; }
    self.input.text = @""; [self.pendingAttachments removeAllObjects]; [self updateAttachments]; [self beginGeneration];
}
- (void)beginGeneration {
    CGMessage *assistant = [CGMessage new]; assistant.role = @"assistant"; assistant.text = @""; [self.conversation.messages addObject:assistant]; self.generating = YES; [self updateSendButton]; [CGStore.shared save]; [self.table reloadData]; [self scrollToBottom:YES];
    self.api = [CGAPIClient new]; __weak typeof(self) weakSelf = self;
    self.api.deltaBlock = ^(NSString *delta) { __strong typeof(weakSelf) self = weakSelf; if (!self) return; CGMessage *last = self.conversation.messages.lastObject; last.text = [last.text stringByAppendingString:delta ?: @""]; NSIndexPath *ip = [NSIndexPath indexPathForRow:self.conversation.messages.count-1 inSection:0]; [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone]; [self scrollToBottom:NO]; };
    self.api.completionBlock = ^(CGAPIResult *result, NSError *error) { __strong typeof(weakSelf) self = weakSelf; if (!self) return; CGMessage *last = self.conversation.messages.lastObject; self.generating = NO; [self updateSendButton];
        if (error) { last.text = last.text.length ? [last.text stringByAppendingFormat:@"\n\nError: %@", error.localizedDescription] : [NSString stringWithFormat:@"Error: %@", error.localizedDescription]; }
        else { if (result.text.length) last.text = result.text; last.sources = [result.sources mutableCopy] ?: [NSMutableArray array]; self.conversation.previousResponseID = result.responseID; for (NSData *d in result.generatedImages) { NSString *p = [self saveGeneratedImage:d]; if (p) [last.generatedImagePaths addObject:p]; } }
        self.conversation.updatedAt = [NSDate date]; [CGStore.shared save]; [self.table reloadData]; [self scrollToBottom:YES];
    };
    CGConversation *requestConversation = [CGConversation fromDictionary:self.conversation.dictionary]; [requestConversation.messages removeLastObject];
    [self.api sendConversation:requestConversation apiKey:CGStore.shared.apiKey];
}
- (void)regenerate { if (self.generating || self.conversation.messages.count < 2) return; CGMessage *last = self.conversation.messages.lastObject; if (![last.role isEqualToString:@"assistant"]) return; [self.conversation.messages removeLastObject]; self.conversation.previousResponseID = nil; [self beginGeneration]; }
- (void)updateSendButton { NSString *name = self.generating ? @"stop.circle.fill" : @"arrow.up.circle.fill"; [self.sendButton setImage:[UIImage systemImageNamed:name] forState:UIControlStateNormal]; self.plusButton.enabled = !self.generating; self.micButton.enabled = !self.generating; }
- (void)scrollToBottom:(BOOL)animated { NSInteger count = self.conversation.messages.count; if (count > 0) [self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:count-1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:animated]; }
- (void)showSettingsRequired { UIAlertController *a = [UIAlertController alertControllerWithTitle:@"API key required" message:@"Add your OpenAI API key in Settings to use native chat." preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; [a addAction:[UIAlertAction actionWithTitle:@"Settings" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ CGSettingsViewController *s=[CGSettingsViewController new]; UINavigationController *n=[[UINavigationController alloc] initWithRootViewController:s]; [self presentViewController:n animated:YES completion:nil]; }]]; [self presentViewController:a animated:YES completion:nil]; }

- (void)attachTapped { if (self.generating) return; UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Attach" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Photo Library" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ [self pickImage:UIImagePickerControllerSourceTypePhotoLibrary]; }]];
    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) [a addAction:[UIAlertAction actionWithTitle:@"Camera" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ [self pickImage:UIImagePickerControllerSourceTypeCamera]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"File" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeImport]; p.delegate = self; p.allowsMultipleSelection = YES; [self presentViewController:p animated:YES completion:nil]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; if (a.popoverPresentationController) a.popoverPresentationController.sourceView = self.plusButton; [self presentViewController:a animated:YES completion:nil]; }
- (void)pickImage:(UIImagePickerControllerSourceType)source { UIImagePickerController *p = [UIImagePickerController new]; p.delegate = self; p.sourceType = source; p.mediaTypes = @[@"public.image"]; [self presentViewController:p animated:YES completion:nil]; }
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info { UIImage *image = info[UIImagePickerControllerOriginalImage]; [picker dismissViewControllerAnimated:YES completion:nil]; if (!image) return; NSData *data = UIImageJPEGRepresentation(image, 0.82); if (data.length > 15*1024*1024) { [self showAttachmentError:@"That image is too large. Keep attachments under 15 MB."]; return; } CGAttachment *a=[CGAttachment new]; a.name=@"photo.jpg"; a.mimeType=@"image/jpeg"; a.data=data; a.image=YES; [self.pendingAttachments addObject:a]; [self updateAttachments]; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { for (NSURL *url in urls) { NSData *d=[NSData dataWithContentsOfURL:url]; if (!d.length) continue; if (d.length>20*1024*1024) { [self showAttachmentError:[NSString stringWithFormat:@"%@ is over 20 MB.",url.lastPathComponent]]; continue; } CGAttachment *a=[CGAttachment new]; a.name=url.lastPathComponent ?: @"file"; a.mimeType=[self mimeForFilename:a.name]; a.data=d; a.image=[a.mimeType hasPrefix:@"image/"]; [self.pendingAttachments addObject:a]; } [self updateAttachments]; }
- (NSString *)mimeForFilename:(NSString *)name { NSString *e=name.pathExtension.lowercaseString; NSDictionary *m=@{@"pdf":@"application/pdf",@"txt":@"text/plain",@"csv":@"text/csv",@"json":@"application/json",@"md":@"text/markdown",@"png":@"image/png",@"jpg":@"image/jpeg",@"jpeg":@"image/jpeg",@"gif":@"image/gif",@"webp":@"image/webp"}; return m[e] ?: @"application/octet-stream"; }
- (void)updateAttachments { if (!self.pendingAttachments.count) { self.attachmentLabel.hidden=YES; self.attachmentLabel.text=@""; return; } self.attachmentLabel.hidden=NO; NSMutableArray *n=[NSMutableArray array]; for(CGAttachment *a in self.pendingAttachments)[n addObject:a.name ?: @"Attachment"]; self.attachmentLabel.text=[NSString stringWithFormat:@"Attached: %@",[n componentsJoinedByString:@", "]]; }
- (void)showAttachmentError:(NSString *)msg { UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Attachment" message:msg preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }

- (void)micTapped { if (self.audioEngine.isRunning) { [self stopSpeech]; return; } [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status){ dispatch_async(dispatch_get_main_queue(), ^{ if(status==SFSpeechRecognizerAuthorizationStatusAuthorized)[self startSpeech]; else [self showAttachmentError:@"Speech recognition permission is required for dictation."]; }); }]; }
- (void)startSpeech { self.speechRecognizer=[[SFSpeechRecognizer alloc] initWithLocale:NSLocale.currentLocale]; self.audioEngine=[AVAudioEngine new]; self.speechRequest=[SFSpeechAudioBufferRecognitionRequest new]; self.speechRequest.shouldReportPartialResults=YES; AVAudioSession *session=AVAudioSession.sharedInstance; [session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionDuckOthers error:nil]; [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil]; AVAudioInputNode *input=self.audioEngine.inputNode; AVAudioFormat *format=[input outputFormatForBus:0]; [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when){ [self.speechRequest appendAudioPCMBuffer:buffer]; }]; [self.audioEngine prepare]; if(![self.audioEngine startAndReturnError:nil])return; [self.micButton setImage:[UIImage systemImageNamed:@"waveform.circle.fill"] forState:UIControlStateNormal]; __weak typeof(self) weakSelf=self; self.speechTask=[self.speechRecognizer recognitionTaskWithRequest:self.speechRequest resultHandler:^(SFSpeechRecognitionResult *result,NSError *error){ __strong typeof(weakSelf) self=weakSelf; if(result)self.input.text=result.bestTranscription.formattedString; if(error||result.isFinal)[self stopSpeech]; }]; }
- (void)stopSpeech { if(self.audioEngine.isRunning){[self.audioEngine stop];[self.audioEngine.inputNode removeTapOnBus:0];} [self.speechRequest endAudio]; [self.speechTask cancel]; self.speechTask=nil; self.speechRequest=nil; self.audioEngine=nil; [self.micButton setImage:[UIImage systemImageNamed:@"waveform"] forState:UIControlStateNormal]; [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil]; }

- (NSString *)saveGeneratedImage:(NSData *)data { NSArray *dirs=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES); NSString *dir=[[dirs firstObject] stringByAppendingPathComponent:@"GeneratedImages"]; [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]; NSString *path=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png",NSUUID.UUID.UUIDString]]; return [data writeToFile:path atomically:YES] ? path : nil; }
@end

#pragma mark - CGAppDelegate.h

@interface CGAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

#pragma mark - CGAppDelegate.m

@implementation CGAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    CGChatViewController *chat = [CGChatViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:chat];
    nav.navigationBar.prefersLargeTitles = NO;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

#pragma mark - main.m

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([CGAppDelegate class]));
    }
}
