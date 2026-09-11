#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>

// Reuse the original v1 native ChatGPT UI as the optional second section of the
// app. Rename its standalone main() so these classes can live inside the shell
// dylib without trying to start a second UIApplication.
#include "../App/Parts/Core.inc"
#include "../App/Parts/API.inc"
#include "../App/Parts/Views.inc"
#include "../App/Parts/ChatA.inc"
#define main CGUnusedNativeChatMain
#include "../App/Parts/ChatB.inc"
#undef main
