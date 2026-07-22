#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <string.h>

static BOOL WriteUTF8(NSString *path, NSString *text) {
    if (path.length == 0) {
        return NO;
    }

    return [text writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:nil];
}

@interface MDLProgressDelegate : NSObject <NSApplicationDelegate>

@property(nonatomic, copy) NSString *statePath;
@property(nonatomic, copy) NSString *cancelPath;
@property(nonatomic, copy) NSString *closedPath;
@property(nonatomic, copy) NSString *readyPath;

@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSProgressIndicator *progressBar;
@property(nonatomic, strong) NSButton *stopButton;
@property(nonatomic, strong) NSTimer *pollTimer;

@property(nonatomic) BOOL finishing;

@end

@implementation MDLProgressDelegate

- (NSTextField *)plainLabelWithFrame:(NSRect)frame
                                font:(NSFont *)font {
    NSTextField *label =
        [[NSTextField alloc] initWithFrame:frame];

    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.font = font;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;

    return label;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    self.finishing = NO;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSRect frame = NSMakeRect(0, 0, 860, 260);

    self.window =
        [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:NSWindowStyleMaskTitled
                        backing:NSBackingStoreBuffered
                          defer:NO];

    self.window.title = @"MDLBSG Compressor";
    self.window.releasedWhenClosed = NO;

    NSView *content = self.window.contentView;

    self.titleLabel =
        [self plainLabelWithFrame:NSMakeRect(40, 158, 780, 34)
                              font:[NSFont systemFontOfSize:18
                                                   weight:NSFontWeightSemibold]];

    self.detailLabel =
        [self plainLabelWithFrame:NSMakeRect(40, 116, 780, 30)
                              font:[NSFont systemFontOfSize:15]];

    self.progressBar =
        [[NSProgressIndicator alloc]
            initWithFrame:NSMakeRect(40, 68, 650, 22)];

    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 100.0;
    self.progressBar.doubleValue = 0.0;

    self.stopButton =
        [[NSButton alloc]
            initWithFrame:NSMakeRect(715, 56, 105, 42)];

    self.stopButton.title = @"Stop";
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.target = self;
    self.stopButton.action = @selector(stopPressed:);

    self.titleLabel.stringValue = @"Preparing MDLBSG compression";
    self.detailLabel.stringValue = @"Preparing...";

    [content addSubview:self.titleLabel];
    [content addSubview:self.detailLabel];
    [content addSubview:self.progressBar];
    [content addSubview:self.stopButton];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    WriteUTF8(self.readyPath, @"ready\n");

    self.pollTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.10
                                         target:self
                                       selector:@selector(pollState:)
                                       userInfo:nil
                                        repeats:YES];
}

- (void)stopPressed:(id)sender {
    (void)sender;

    if (self.finishing) {
        return;
    }

    self.stopButton.enabled = NO;
    self.detailLabel.stringValue = @"Stopping...";

    WriteUTF8(self.cancelPath, @"cancel\n");
}

- (void)pollState:(NSTimer *)timer {
    (void)timer;

    if (self.finishing) {
        return;
    }

    NSString *state =
        [NSString stringWithContentsOfFile:self.statePath
                                  encoding:NSUTF8StringEncoding
                                     error:nil];

    if (state.length == 0) {
        return;
    }

    if ([state hasPrefix:@"CLOSE"]) {
        [self finishAndExit];
        return;
    }

    NSArray<NSString *> *lines =
        [state componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]];

    if (lines.count < 1) {
        return;
    }

    double percent =
        [[lines objectAtIndex:0] doubleValue];

    if (percent < 0.0) {
        percent = 0.0;
    }

    if (percent > 100.0) {
        percent = 100.0;
    }

    self.progressBar.doubleValue = percent;

    if (lines.count >= 2) {
        NSString *title =
            [lines objectAtIndex:1];

        if (title.length > 0) {
            self.titleLabel.stringValue = title;
        }
    }

    if (lines.count >= 3) {
        NSString *detail =
            [lines objectAtIndex:2];

        if (detail.length > 0) {
            self.detailLabel.stringValue = detail;
        }
    }
}

- (void)finishAndExit {
    if (self.finishing) {
        return;
    }

    self.finishing = YES;

    [self.pollTimer invalidate];
    self.pollTimer = nil;

    self.stopButton.enabled = NO;

    [self.window orderOut:nil];
    [self.window close];

    WriteUTF8(self.closedPath, @"closed\n");

    [NSApp terminate:nil];
}

@end

static int RunSelfTest(void) {
    printf("MDLBSG_PROGRESS_WINDOW_SELF_TEST_PASS\n");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 &&
            strcmp(argv[1], "--self-test") == 0) {
            return RunSelfTest();
        }

        NSString *statePath = nil;
        NSString *cancelPath = nil;
        NSString *closedPath = nil;
        NSString *readyPath = nil;

        for (int i = 1; i < argc; ++i) {
            NSString *arg =
                [NSString stringWithUTF8String:argv[i]];

            if ([arg isEqualToString:@"--state"] &&
                i + 1 < argc) {
                statePath =
                    [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--cancel"] &&
                       i + 1 < argc) {
                cancelPath =
                    [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--closed"] &&
                       i + 1 < argc) {
                closedPath =
                    [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--ready"] &&
                       i + 1 < argc) {
                readyPath =
                    [NSString stringWithUTF8String:argv[++i]];
            }
        }

        if (statePath.length == 0 ||
            cancelPath.length == 0 ||
            closedPath.length == 0 ||
            readyPath.length == 0) {
            fprintf(
                stderr,
                "usage: mdlbsg_progress_window "
                "--state path --cancel path "
                "--closed path --ready path\n"
            );

            return 64;
        }

        NSApplication *application =
            [NSApplication sharedApplication];

        MDLProgressDelegate *delegate =
            [[MDLProgressDelegate alloc] init];

        delegate.statePath = statePath;
        delegate.cancelPath = cancelPath;
        delegate.closedPath = closedPath;
        delegate.readyPath = readyPath;

        application.delegate = delegate;

        [application run];

        return 0;
    }
}
