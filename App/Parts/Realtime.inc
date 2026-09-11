#pragma mark - CGRealtimeVoiceViewController

typedef void (^CGVoiceChangeHandler)(void);

@interface CGRealtimeVoiceViewController : UIViewController <NSURLSessionWebSocketDelegate>
@property (nonatomic, copy) CGVoiceChangeHandler changeHandler;
- (instancetype)initWithConversation:(CGConversation *)conversation;
@end

@interface CGRealtimeVoiceViewController ()
@property (nonatomic, strong) CGConversation *conversation;
@property (nonatomic, strong) NSURLSession *socketSession;
@property (nonatomic, strong) NSURLSessionWebSocketTask *socket;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) AVAudioPlayerNode *player;
@property (nonatomic, strong) AVAudioConverter *inputConverter;
@property (nonatomic, strong) AVAudioFormat *streamFormat;
@property (nonatomic, assign) BOOL audioTapInstalled;
@property (nonatomic, assign) BOOL muted;
@property (nonatomic, assign) BOOL stopping;
@property (nonatomic, assign) BOOL sessionReady;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UIView *orb;
@property (nonatomic, strong) UIImageView *orbIcon;
@property (nonatomic, strong) UIButton *muteButton;
@property (nonatomic, strong) UIButton *closeButton;
@end

@implementation CGRealtimeVoiceViewController

- (instancetype)initWithConversation:(CGConversation *)conversation {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _conversation = conversation;
        _modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Voice";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Connecting…";
    self.statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];

    self.orb = [UIView new];
    self.orb.translatesAutoresizingMaskIntoConstraints = NO;
    self.orb.backgroundColor = UIColor.labelColor;
    self.orb.layer.cornerRadius = 84;
    self.orb.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:self.orb];

    self.orbIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:54 weight:UIImageSymbolWeightMedium]]];
    self.orbIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.orbIcon.tintColor = UIColor.systemBackgroundColor;
    self.orbIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.orb addSubview:self.orbIcon];

    self.captionLabel = [UILabel new];
    self.captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.captionLabel.numberOfLines = 5;
    self.captionLabel.textAlignment = NSTextAlignmentCenter;
    self.captionLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightRegular];
    self.captionLabel.textColor = UIColor.labelColor;
    self.captionLabel.text = @"Talk naturally. You can interrupt at any time.";
    [self.view addSubview:self.captionLabel];

    self.muteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.muteButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.muteButton.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.muteButton.layer.cornerRadius = 30;
    [self.muteButton setImage:[UIImage systemImageNamed:@"mic.fill"] forState:UIControlStateNormal];
    self.muteButton.tintColor = UIColor.labelColor;
    [self.muteButton addTarget:self action:@selector(toggleMute) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.muteButton];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.closeButton.backgroundColor = UIColor.labelColor;
    self.closeButton.layer.cornerRadius = 30;
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    self.closeButton.tintColor = UIColor.systemBackgroundColor;
    [self.closeButton addTarget:self action:@selector(closeVoice) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14],
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.orb.widthAnchor constraintEqualToConstant:168],
        [self.orb.heightAnchor constraintEqualToConstant:168],
        [self.orb.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.orb.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-70],
        [self.orbIcon.centerXAnchor constraintEqualToAnchor:self.orb.centerXAnchor],
        [self.orbIcon.centerYAnchor constraintEqualToAnchor:self.orb.centerYAnchor],
        [self.orbIcon.widthAnchor constraintEqualToConstant:86],
        [self.orbIcon.heightAnchor constraintEqualToConstant:86],
        [self.captionLabel.topAnchor constraintEqualToAnchor:self.orb.bottomAnchor constant:38],
        [self.captionLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28],
        [self.captionLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
        [self.muteButton.widthAnchor constraintEqualToConstant:60],
        [self.muteButton.heightAnchor constraintEqualToConstant:60],
        [self.closeButton.widthAnchor constraintEqualToConstant:60],
        [self.closeButton.heightAnchor constraintEqualToConstant:60],
        [self.muteButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-24],
        [self.closeButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-24],
        [self.muteButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor constant:-50],
        [self.closeButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor constant:50]
    ]];

    [self connectRealtime];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) [self shutdown];
}

- (NSString *)contextInstructions {
    NSMutableString *instructions = [NSMutableString stringWithString:@"You are ChatGPT in a live voice conversation. Be natural, useful and conversational. Keep answers concise unless the user asks for detail. The user may interrupt you; stop and listen when they do.\n"];
    NSArray *messages = self.conversation.messages ?: @[];
    NSInteger start = MAX((NSInteger)messages.count - 10, 0);
    if (messages.count > 0) [instructions appendString:@"\nRecent text-chat context:\n"];
    for (NSInteger i = start; i < (NSInteger)messages.count; i++) {
        CGMessage *m = messages[i];
        if (!m.text.length) continue;
        NSString *speaker = [m.role isEqualToString:@"assistant"] ? @"Assistant" : @"User";
        NSString *text = m.text.length > 900 ? [[m.text substringToIndex:900] stringByAppendingString:@"…"] : m.text;
        [instructions appendFormat:@"%@: %@\n", speaker, text];
        if (instructions.length > 7000) break;
    }
    return instructions;
}

- (void)connectRealtime {
    NSString *key = CGStore.shared.apiKey;
    if (!key.length) { [self failWithMessage:@"Add your OpenAI API key in Settings first."]; return; }
    NSURL *url = [NSURL URLWithString:@"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    self.socketSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    self.socket = [self.socketSession webSocketTaskWithRequest:request];
    [self.socket resume];
    [self receiveNext];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    self.statusLabel.text = @"Setting up voice…";
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    if (!self.stopping) [self failWithMessage:@"Voice connection closed. Tap X and try again."];
}

- (void)receiveNext {
    if (self.stopping || !self.socket) return;
    __weak typeof(self) weakSelf = self;
    [self.socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.stopping) return;
        if (error) { [self failWithMessage:error.localizedDescription ?: @"Voice connection failed."]; return; }
        NSString *text = message.string;
        if (!text && message.data.length) text = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
        if (text.length) [self handleServerJSON:text];
        [self receiveNext];
    }];
}

- (void)handleServerJSON:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![event isKindOfClass:NSDictionary.class]) return;
    NSString *type = event[@"type"];

    if ([type isEqualToString:@"session.created"]) {
        [self sendSessionUpdate];
    } else if ([type isEqualToString:@"session.updated"]) {
        if (!self.sessionReady) { self.sessionReady = YES; [self requestAudioPermissionAndStart]; }
    } else if ([type isEqualToString:@"input_audio_buffer.speech_started"]) {
        [self interruptPlayback]; self.statusLabel.text = self.muted ? @"Muted" : @"Listening…";
    } else if ([type isEqualToString:@"conversation.item.input_audio_transcription.delta"]) {
        NSString *delta = event[@"delta"]; if (delta.length) self.captionLabel.text = [NSString stringWithFormat:@"You: %@", delta];
    } else if ([type isEqualToString:@"conversation.item.input_audio_transcription.completed"]) {
        NSString *transcript = event[@"transcript"]; if (transcript.length) { self.captionLabel.text = [NSString stringWithFormat:@"You: %@", transcript]; [self appendTurn:@"user" text:transcript]; }
    } else if ([type isEqualToString:@"response.output_audio.delta"]) {
        NSString *b64 = event[@"delta"];
        NSData *pcm = [[NSData alloc] initWithBase64EncodedString:b64 ?: @"" options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (pcm.length) { self.statusLabel.text = @"Speaking…"; [self playPCM16:pcm]; }
    } else if ([type isEqualToString:@"response.output_audio_transcript.delta"]) {
        NSString *delta = event[@"delta"]; if (delta.length) self.captionLabel.text = [NSString stringWithFormat:@"ChatGPT: %@", delta];
    } else if ([type isEqualToString:@"response.output_audio_transcript.done"]) {
        NSString *transcript = event[@"transcript"]; if (transcript.length) { self.captionLabel.text = [NSString stringWithFormat:@"ChatGPT: %@", transcript]; [self appendTurn:@"assistant" text:transcript]; }
    } else if ([type isEqualToString:@"response.output_audio.done"] || [type isEqualToString:@"response.done"]) {
        if (!self.muted) self.statusLabel.text = @"Listening…";
    } else if ([type isEqualToString:@"error"]) {
        NSDictionary *err = event[@"error"];
        [self failWithMessage:err[@"message"] ?: @"Realtime voice returned an error."];
    }
}

- (void)sendSessionUpdate {
    NSDictionary *audioInput = @{
        @"format": @{ @"type": @"audio/pcm", @"rate": @24000 },
        @"noise_reduction": @{ @"type": @"near_field" },
        @"transcription": @{ @"model": @"gpt-4o-mini-transcribe", @"language": @"en" },
        @"turn_detection": @{ @"type": @"semantic_vad", @"eagerness": @"auto", @"create_response": @YES, @"interrupt_response": @YES }
    };
    NSDictionary *audioOutput = @{
        @"format": @{ @"type": @"audio/pcm", @"rate": @24000 },
        @"voice": @"marin"
    };
    NSDictionary *session = @{
        @"type": @"realtime",
        @"instructions": [self contextInstructions],
        @"output_modalities": @[@"audio"],
        @"reasoning": @{ @"effort": @"medium" },
        @"audio": @{ @"input": audioInput, @"output": audioOutput }
    };
    [self sendEvent:@{ @"type": @"session.update", @"session": session }];
}

- (void)sendEvent:(NSDictionary *)event {
    if (self.stopping || !self.socket) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!json.length) return;
    [self.socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:json] completionHandler:^(NSError *error) {}];
}

- (void)requestAudioPermissionAndStart {
    __weak typeof(self) weakSelf = self;
    [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (!granted) { [self failWithMessage:@"Microphone permission is required for live voice."]; return; }
            [self startAudio];
        });
    }];
}

- (void)startAudio {
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeVoiceChat options:options error:&error] ||
        ![session setActive:YES error:&error]) {
        [self failWithMessage:error.localizedDescription ?: @"Could not start audio."]; return;
    }

    self.audioEngine = [AVAudioEngine new];
    self.player = [AVAudioPlayerNode new];
    self.streamFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:24000 channels:1];
    [self.audioEngine attachNode:self.player];
    [self.audioEngine connect:self.player to:self.audioEngine.mainMixerNode format:self.streamFormat];

    AVAudioInputNode *input = self.audioEngine.inputNode;
    AVAudioFormat *inputFormat = [input outputFormatForBus:0];
    self.inputConverter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:self.streamFormat];
    if (!self.inputConverter) { [self failWithMessage:@"Could not configure microphone audio."]; return; }

    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:2048 format:inputFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.stopping || self.muted) return;
        [self convertAndSendInput:buffer inputFormat:inputFormat];
    }];
    self.audioTapInstalled = YES;
    [self.audioEngine prepare];
    if (![self.audioEngine startAndReturnError:&error]) { [self failWithMessage:error.localizedDescription ?: @"Microphone could not start."]; return; }
    [self.player play];
    self.statusLabel.text = @"Listening…";
    [self beginPulse];
}

- (void)convertAndSendInput:(AVAudioPCMBuffer *)buffer inputFormat:(AVAudioFormat *)inputFormat {
    if (!buffer.frameLength || !self.inputConverter) return;
    double ratio = 24000.0 / MAX(inputFormat.sampleRate, 1.0);
    AVAudioFrameCount capacity = (AVAudioFrameCount)ceil((double)buffer.frameLength * ratio) + 32;
    AVAudioPCMBuffer *converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.streamFormat frameCapacity:capacity];
    __block BOOL supplied = NO;
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [self.inputConverter convertToBuffer:converted error:&error withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
        if (supplied) { *outStatus = AVAudioConverterInputStatus_NoDataNow; return nil; }
        supplied = YES; *outStatus = AVAudioConverterInputStatus_HaveData; return buffer;
    }];
    if (status != AVAudioConverterOutputStatus_HaveData || error || converted.frameLength == 0) return;
    float *samples = converted.floatChannelData[0];
    NSUInteger frames = converted.frameLength;
    NSMutableData *pcm = [NSMutableData dataWithLength:frames * sizeof(int16_t)];
    int16_t *dest = pcm.mutableBytes;
    for (NSUInteger i = 0; i < frames; i++) {
        float v = fmaxf(-1.0f, fminf(1.0f, samples[i]));
        dest[i] = (int16_t)lrintf(v * 32767.0f);
    }
    NSString *b64 = [pcm base64EncodedStringWithOptions:0];
    if (b64.length) [self sendEvent:@{ @"type": @"input_audio_buffer.append", @"audio": b64 }];
}

- (void)playPCM16:(NSData *)data {
    if (!self.audioEngine.isRunning || !self.player || data.length < 2) return;
    NSUInteger frames = data.length / sizeof(int16_t);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.streamFormat frameCapacity:(AVAudioFrameCount)frames];
    buffer.frameLength = (AVAudioFrameCount)frames;
    const int16_t *src = data.bytes;
    float *dest = buffer.floatChannelData[0];
    for (NSUInteger i = 0; i < frames; i++) dest[i] = (float)src[i] / 32768.0f;
    [self.player scheduleBuffer:buffer completionHandler:nil];
    if (!self.player.isPlaying) [self.player play];
}

- (void)interruptPlayback {
    if (self.player) { [self.player stop]; if (self.audioEngine.isRunning) [self.player play]; }
}

- (void)appendTurn:(NSString *)role text:(NSString *)text {
    NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!clean.length) return;
    CGMessage *last = self.conversation.messages.lastObject;
    if ([last.role isEqualToString:role] && [last.text isEqualToString:clean]) return;
    CGMessage *message = [CGMessage new]; message.role = role; message.text = clean;
    [self.conversation.messages addObject:message]; self.conversation.updatedAt = [NSDate date];
    if ([role isEqualToString:@"user"] && [self.conversation.title isEqualToString:@"New chat"]) self.conversation.title = clean.length > 42 ? [[clean substringToIndex:42] stringByAppendingString:@"…"] : clean;
    [CGStore.shared save];
    if (self.changeHandler) self.changeHandler();
}

- (void)toggleMute {
    self.muted = !self.muted;
    NSString *symbol = self.muted ? @"mic.slash.fill" : @"mic.fill";
    [self.muteButton setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    self.statusLabel.text = self.muted ? @"Muted" : @"Listening…";
}

- (void)beginPulse {
    [self.orb.layer removeAllAnimations];
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @0.96; pulse.toValue = @1.04; pulse.duration = 0.9; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
    [self.orb.layer addAnimation:pulse forKey:@"voicePulse"];
}

- (void)failWithMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = @"Voice unavailable";
        self.captionLabel.text = message ?: @"Voice failed.";
        self.orb.backgroundColor = UIColor.secondarySystemBackgroundColor;
        self.orbIcon.tintColor = UIColor.secondaryLabelColor;
    });
}

- (void)closeVoice { [self shutdown]; [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)shutdown {
    if (self.stopping) return;
    self.stopping = YES;
    if (self.audioTapInstalled) { [self.audioEngine.inputNode removeTapOnBus:0]; self.audioTapInstalled = NO; }
    [self.player stop]; [self.audioEngine stop];
    self.player = nil; self.audioEngine = nil; self.inputConverter = nil;
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [self.socketSession invalidateAndCancel]; self.socket = nil; self.socketSession = nil;
}

@end
