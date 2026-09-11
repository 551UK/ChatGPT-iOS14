#pragma mark - Live voice chat integration

@implementation CGChatViewController (LiveVoice)
- (void)voiceTapped {
    if (self.generating) return;
    if (!CGStore.shared.apiKey.length) { [self showSettingsRequired]; return; }
    if (self.audioEngine.isRunning) [self stopSpeech];
    [self.view endEditing:YES];
    CGRealtimeVoiceViewController *voice = [[CGRealtimeVoiceViewController alloc] initWithConversation:self.conversation];
    voice.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak typeof(self) weakSelf = self;
    voice.changeHandler = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self reloadConversation];
    };
    [self presentViewController:voice animated:YES completion:nil];
}
@end
