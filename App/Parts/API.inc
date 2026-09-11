#pragma mark - CGAPIClient.h

@interface CGAPIResult : NSObject
@property (nonatomic, copy) NSString *responseID;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSArray<NSDictionary *> *sources;
@property (nonatomic, strong) NSArray<NSData *> *generatedImages;
@end

typedef void (^CGAPIDeltaBlock)(NSString *delta);
typedef void (^CGAPICompletionBlock)(CGAPIResult *result, NSError *error);

@interface CGAPIClient : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) CGAPIDeltaBlock deltaBlock;
@property (nonatomic, copy) CGAPICompletionBlock completionBlock;
- (void)sendConversation:(CGConversation *)conversation apiKey:(NSString *)apiKey;
- (void)cancel;
@end

#pragma mark - CGAPIClient.m

@implementation CGAPIResult @end

@interface CGAPIClient ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *rawData;
@property (nonatomic, strong) NSMutableString *sseBuffer;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) CGAPIResult *result;
@property (nonatomic, assign) BOOL completedCallback;
@end

@implementation CGAPIClient

- (NSDictionary *)contentForMessage:(CGMessage *)m {
    if (m.attachments.count == 0) return @{ @"role": m.role ?: @"user", @"content": m.text ?: @"" };
    NSMutableArray *parts = [NSMutableArray array];
    if (m.text.length) [parts addObject:@{ @"type": @"input_text", @"text": m.text }];
    for (CGAttachment *a in m.attachments) {
        NSString *b64 = [a.data base64EncodedStringWithOptions:0] ?: @"";
        NSString *mime = a.mimeType.length ? a.mimeType : @"application/octet-stream";
        NSString *dataURL = [NSString stringWithFormat:@"data:%@;base64,%@", mime, b64];
        if (a.image) {
            [parts addObject:@{ @"type": @"input_image", @"image_url": dataURL, @"detail": @"auto" }];
        } else {
            [parts addObject:@{ @"type": @"input_file", @"file_data": dataURL, @"filename": a.name ?: @"attachment" }];
        }
    }
    return @{ @"role": m.role ?: @"user", @"content": parts };
}

- (void)sendConversation:(CGConversation *)conversation apiKey:(NSString *)apiKey {
    [self cancel];
    self.completedCallback = NO;
    self.rawData = [NSMutableData data];
    self.sseBuffer = [NSMutableString string];
    self.statusCode = 0;
    self.result = [CGAPIResult new];
    self.result.text = @"";
    self.result.sources = @[];
    self.result.generatedImages = @[];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    CGStore *store = CGStore.shared;
    body[@"model"] = store.model;
    body[@"stream"] = @YES;
    body[@"store"] = @YES;
    body[@"instructions"] = @"You are ChatGPT. Be helpful, accurate, natural, and concise unless the user asks for detail. Use tools when they materially improve the answer. Preserve useful formatting such as headings, bullets, code blocks and tables in plain Markdown.";
    body[@"reasoning"] = @{ @"effort": store.reasoningEffort };

    NSMutableArray *tools = [NSMutableArray array];
    if (store.webSearchEnabled) [tools addObject:@{ @"type": @"web_search" }];
    if (store.imageGenerationEnabled) [tools addObject:@{ @"type": @"image_generation" }];
    if (store.codeInterpreterEnabled) [tools addObject:@{ @"type": @"code_interpreter", @"container": @{ @"type": @"auto" } }];
    if (tools.count) body[@"tools"] = tools;

    CGMessage *latest = conversation.messages.lastObject;
    if (conversation.previousResponseID.length && [latest.role isEqualToString:@"user"]) {
        body[@"previous_response_id"] = conversation.previousResponseID;
        body[@"input"] = @[ [self contentForMessage:latest] ];
    } else {
        NSMutableArray *input = [NSMutableArray array];
        for (CGMessage *m in conversation.messages) {
            if ([m.role isEqualToString:@"assistant"] && !m.text.length) continue;
            if ([m.role isEqualToString:@"assistant"] && m.attachments.count == 0) {
                [input addObject:@{ @"role": @"assistant", @"content": m.text ?: @"" }];
            } else {
                [input addObject:[self contentForMessage:m]];
            }
        }
        body[@"input"] = input;
    }

    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!json) {
        if (self.completionBlock) self.completionBlock(nil, jsonError);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.openai.com/v1/responses"]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    req.timeoutInterval = 300;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    self.task = [self.session dataTaskWithRequest:req];
    [self.task resume];
}

- (void)cancel {
    [self.task cancel];
    [self.session invalidateAndCancel];
    self.task = nil;
    self.session = nil;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) self.statusCode = ((NSHTTPURLResponse *)response).statusCode;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.rawData appendData:data];
    NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!chunk.length) return;
    chunk = [chunk stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    [self.sseBuffer appendString:chunk];
    while (YES) {
        NSRange r = [self.sseBuffer rangeOfString:@"\n\n"];
        if (r.location == NSNotFound) break;
        NSString *event = [self.sseBuffer substringToIndex:r.location];
        [self.sseBuffer deleteCharactersInRange:NSMakeRange(0, NSMaxRange(r))];
        [self handleSSEEvent:event];
    }
}

- (void)handleSSEEvent:(NSString *)event {
    NSArray *lines = [event componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableString *payload = [NSMutableString string];
    for (NSString *line in lines) {
        if ([line hasPrefix:@"data:"]) {
            NSString *p = [line substringFromIndex:5];
            if ([p hasPrefix:@" "]) p = [p substringFromIndex:1];
            if (payload.length) [payload appendString:@"\n"];
            [payload appendString:p];
        }
    }
    if (!payload.length || [payload isEqualToString:@"[DONE]"]) return;
    NSData *d = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) return;
    NSString *type = obj[@"type"];
    if ([type isEqualToString:@"response.output_text.delta"]) {
        NSString *delta = obj[@"delta"];
        if (delta.length) {
            self.result.text = [self.result.text stringByAppendingString:delta];
            if (self.deltaBlock) self.deltaBlock(delta);
        }
    } else if ([type isEqualToString:@"response.completed"]) {
        NSDictionary *response = obj[@"response"];
        [self finalizeFromResponse:response];
        [self fireCompletion:nil];
    } else if ([type isEqualToString:@"error"] || [type isEqualToString:@"response.failed"]) {
        NSDictionary *errObj = obj[@"error"] ?: obj[@"response"][@"error"];
        NSString *message = errObj[@"message"] ?: @"OpenAI request failed.";
        NSError *err = [NSError errorWithDomain:@"ChatGPT14.API" code:self.statusCode userInfo:@{NSLocalizedDescriptionKey:message}];
        [self fireCompletion:err];
    }
}

- (void)finalizeFromResponse:(NSDictionary *)response {
    if (![response isKindOfClass:NSDictionary.class]) return;
    self.result.responseID = response[@"id"];
    NSMutableString *finalText = [NSMutableString string];
    NSMutableArray *sources = [NSMutableArray array];
    NSMutableArray *images = [NSMutableArray array];
    NSMutableSet *seenURLs = [NSMutableSet set];
    for (NSDictionary *item in response[@"output"] ?: @[]) {
        NSString *type = item[@"type"];
        if ([type isEqualToString:@"message"]) {
            for (NSDictionary *content in item[@"content"] ?: @[]) {
                if ([content[@"type"] isEqualToString:@"output_text"]) {
                    NSString *text = content[@"text"];
                    if (text.length) {
                        if (finalText.length) [finalText appendString:@"\n"];
                        [finalText appendString:text];
                    }
                    for (NSDictionary *ann in content[@"annotations"] ?: @[]) {
                        if ([ann[@"type"] isEqualToString:@"url_citation"] && [ann[@"url"] length]) {
                            NSString *url = ann[@"url"];
                            if (![seenURLs containsObject:url]) {
                                [seenURLs addObject:url];
                                [sources addObject:@{ @"title": ann[@"title"] ?: url, @"url": url }];
                            }
                        }
                    }
                }
            }
        } else if ([type isEqualToString:@"image_generation_call"]) {
            NSString *b64 = item[@"result"];
            NSData *img = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (img.length) [images addObject:img];
        }
    }
    if (finalText.length) self.result.text = finalText;
    self.result.sources = sources;
    self.result.generatedImages = images;
}

- (void)fireCompletion:(NSError *)error {
    if (self.completedCallback) return;
    self.completedCallback = YES;
    CGAPICompletionBlock cb = self.completionBlock;
    if (cb) cb(error ? nil : self.result, error);
    [self.session finishTasksAndInvalidate];
    self.task = nil;
    self.session = nil;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.completedCallback) return;
    if (error && error.code != NSURLErrorCancelled) {
        [self fireCompletion:error];
        return;
    }
    if (error.code == NSURLErrorCancelled) return;
    if (self.statusCode >= 400) {
        NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:self.rawData options:0 error:nil];
        NSString *message = obj[@"error"][@"message"] ?: [NSHTTPURLResponse localizedStringForStatusCode:self.statusCode];
        NSError *e = [NSError errorWithDomain:@"ChatGPT14.API" code:self.statusCode userInfo:@{NSLocalizedDescriptionKey:message ?: @"Request failed"}];
        [self fireCompletion:e];
    } else if (!self.completedCallback) {
        [self fireCompletion:[NSError errorWithDomain:@"ChatGPT14.API" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"The response ended unexpectedly."}]];
    }
}
@end
