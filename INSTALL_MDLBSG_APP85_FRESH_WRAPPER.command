#!/usr/bin/env bash
set -euo pipefail

cd "$HOME"

TITLE="MDLBSG APP 85 — FRESH CONDITIONAL WRAPPER"
BIN="$HOME/.mdlbsg/bin"
SRCROOT="$HOME/.mdlbsg/app85_source"
STAMP="$(date '+%Y%m%d_%H%M%S')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdlbsg-app85.XXXXXX")"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo
  echo "INSTALL FAILED: $*" >&2
  echo "Nothing below this failure should be treated as installed proof." >&2
  exit 1
}

echo "============================================================"
echo "$TITLE"
echo "============================================================"
echo
echo "This replaces only the Compressor's window wrapper."
echo "The compressor core, modes, archive format, and Decompressor are untouched."
echo

for tool in \
  /usr/bin/clang \
  /usr/bin/osacompile \
  /usr/bin/osadecompile \
  /usr/bin/codesign \
  /usr/libexec/PlistBuddy
 do
  [ -x "$tool" ] || fail "required macOS tool is missing: $tool"
done

mkdir -p "$BIN" "$SRCROOT"

HANDLER="$BIN/mdlbsg_droplet_handler.sh"
DETACH="$BIN/mdlbsg_detached_spawn"
RESULTS="$HOME/.mdlbsg/results_dialog.applescript"
MENU="$HOME/.mdlbsg/launcher_dialog.applescript"

for required in "$HANDLER" "$DETACH" "$RESULTS" "$MENU"
do
  [ -e "$required" ] || fail "required working App 82 component is missing: $required"
done

[ -x "$HANDLER" ] || chmod +x "$HANDLER"
[ -x "$DETACH" ] || chmod +x "$DETACH"

if [ -d "/Applications/MDLBSG Compressor.app" ]; then
  APP="/Applications/MDLBSG Compressor.app"
elif [ -d "$HOME/Applications/MDLBSG Compressor.app" ]; then
  APP="$HOME/Applications/MDLBSG Compressor.app"
else
  fail "the currently installed MDLBSG Compressor app was not found"
fi

APPDIR="$(dirname "$APP")"
WRAPPER_SOURCE="$WORK/mdlbsg_app85_wrapper.m"
WRAPPER_BUILD="$WORK/mdlbsg_app85_wrapper"
APPLESCRIPT_SOURCE="$WORK/MDLBSG_Compressor_App85.applescript"
STAGE_APP="$WORK/MDLBSG Compressor.app"
PROOF_TEXT="$WORK/staged_app85.decompiled.applescript"

cat > "$WRAPPER_SOURCE" <<'OBJC'
#import <Cocoa/Cocoa.h>
#import <signal.h>
#import <unistd.h>

static NSString *MDLRoot(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".mdlbsg"];
}

static void AppendLaunchLog(NSString *message) {
    NSString *root = MDLRoot();
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *path = [root stringByAppendingPathComponent:@"launch.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    }
}

@interface MDLApp85Wrapper : NSObject <NSApplicationDelegate>
@property(nonatomic, copy) NSArray<NSString *> *inputPaths;
@property(nonatomic, copy) NSString *destination;
@property(nonatomic) NSInteger currentIndex;
@property(nonatomic) BOOL cancelled;

@property(nonatomic, strong) NSMutableArray<NSString *> *resultLines;
@property(nonatomic, strong) NSWindow *progressWindow;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSProgressIndicator *progressBar;
@property(nonatomic, strong) NSButton *stopButton;

@property(nonatomic, strong) NSTask *task;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSFileHandle *outputHandle;
@property(nonatomic, copy) NSString *progressPath;
@property(nonatomic, copy) NSString *outputPath;
@property(nonatomic, strong) NSDate *startedAt;
@property(nonatomic, strong) NSDate *encodingStartedAt;
@end

@implementation MDLApp85Wrapper

- (instancetype)initWithPaths:(NSArray<NSString *> *)paths destination:(NSString *)destination {
    self = [super init];
    if (self) {
        _inputPaths = [paths copy];
        _destination = [destination copy];
        _resultLines = [NSMutableArray array];
        _currentIndex = 0;
        _cancelled = NO;
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp activateIgnoringOtherApps:YES];
    [self buildProgressWindow];

    AppendLaunchLog([NSString stringWithFormat:@"app85-wrapper-start items=%lu",
                     (unsigned long)self.inputPaths.count]);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self startCurrentItem];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (NSTextField *)plainLabelWithFrame:(NSRect)frame font:(NSFont *)font {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.font = font;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return label;
}

- (void)buildProgressWindow {
    self.progressWindow = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 760, 205)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];

    self.progressWindow.title = @"MDLBSG Compressor";
    self.progressWindow.releasedWhenClosed = NO;
    self.progressWindow.movableByWindowBackground = YES;

    [[self.progressWindow standardWindowButton:NSWindowCloseButton] setHidden:YES];
    [[self.progressWindow standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    [[self.progressWindow standardWindowButton:NSWindowZoomButton] setHidden:YES];

    NSView *content = self.progressWindow.contentView;

    self.titleLabel = [self plainLabelWithFrame:NSMakeRect(34, 132, 690, 31)
                                           font:[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold]];
    self.detailLabel = [self plainLabelWithFrame:NSMakeRect(34, 96, 690, 27)
                                            font:[NSFont systemFontOfSize:14 weight:NSFontWeightRegular]];

    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(34, 57, 570, 20)];
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 100.0;
    self.progressBar.doubleValue = 0.0;

    self.stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(625, 45, 100, 40)];
    self.stopButton.title = @"Stop";
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.target = self;
    self.stopButton.action = @selector(stopPressed:);

    [content addSubview:self.titleLabel];
    [content addSubview:self.detailLabel];
    [content addSubview:self.progressBar];
    [content addSubview:self.stopButton];

    [self.progressWindow center];
    [self.progressWindow makeKeyAndOrderFront:nil];
}

- (NSString *)displayNameForPath:(NSString *)path {
    NSString *name = path.lastPathComponent;
    return name.length > 0 ? name : path;
}

- (void)setPreparingText {
    NSString *path = self.inputPaths[(NSUInteger)self.currentIndex];
    NSString *name = [self displayNameForPath:path];

    if (self.inputPaths.count > 1) {
        self.titleLabel.stringValue = [NSString stringWithFormat:@"Compressing %@ (%ld of %lu)",
                                       name,
                                       (long)(self.currentIndex + 1),
                                       (unsigned long)self.inputPaths.count];
    } else {
        self.titleLabel.stringValue = [NSString stringWithFormat:@"Compressing %@", name];
    }

    self.detailLabel.stringValue = @"Preparing...";
    self.progressBar.doubleValue = 0.0;
    self.stopButton.enabled = YES;
}

- (void)startCurrentItem {
    if (self.cancelled || self.currentIndex >= (NSInteger)self.inputPaths.count) {
        [self finishAllItems];
        return;
    }

    [self setPreparingText];

    NSString *input = self.inputPaths[(NSUInteger)self.currentIndex];
    NSString *token = [NSString stringWithFormat:@"mdlbsg_app85_%d_%@",
                       getpid(), NSUUID.UUID.UUIDString];

    self.progressPath = [NSTemporaryDirectory() stringByAppendingPathComponent:token];
    self.outputPath = [self.progressPath stringByAppendingString:@".out"];

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:self.progressPath error:nil];
    [fm removeItemAtPath:self.outputPath error:nil];
    [fm createFileAtPath:self.outputPath contents:nil attributes:nil];

    self.outputHandle = [NSFileHandle fileHandleForWritingAtPath:self.outputPath];
    if (!self.outputHandle) {
        [self.resultLines addObject:[NSString stringWithFormat:@"Error: could not create output capture for %@",
                                     [self displayNameForPath:input]]];
        self.currentIndex += 1;
        [self startCurrentItem];
        return;
    }

    NSString *handler = [MDLRoot() stringByAppendingPathComponent:@"bin/mdlbsg_droplet_handler.sh"];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/bash";
    task.arguments = @[handler, input, self.progressPath, self.destination];
    task.standardOutput = self.outputHandle;
    task.standardError = self.outputHandle;
    self.task = task;

    self.startedAt = [NSDate date];
    self.encodingStartedAt = nil;

    __weak MDLApp85Wrapper *weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MDLApp85Wrapper *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf compressionTaskFinished:finishedTask];
        });
    };

    @try {
        [task launch];
    } @catch (NSException *exception) {
        [self.outputHandle closeFile];
        self.outputHandle = nil;
        self.task = nil;

        [self.resultLines addObject:[NSString stringWithFormat:@"Error launching compression for %@: %@",
                                     [self displayNameForPath:input],
                                     exception.reason ?: @"unknown launch error"]];
        self.currentIndex += 1;
        [self startCurrentItem];
        return;
    }

    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                   target:self
                                                 selector:@selector(updateProgress:)
                                                 userInfo:nil
                                                  repeats:YES];
}

- (NSArray<NSString *> *)tokensFromProgressText:(NSString *)raw {
    NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:
                                  NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) {
            [tokens addObject:part];
        }
    }
    return tokens;
}

- (NSString *)formatSeconds:(double)seconds {
    NSInteger whole = MAX(0, (NSInteger)llround(seconds));
    if (whole < 60) {
        return [NSString stringWithFormat:@"%lds", (long)whole];
    }
    if (whole < 3600) {
        return [NSString stringWithFormat:@"%ldm %lds",
                (long)(whole / 60), (long)(whole % 60)];
    }
    return [NSString stringWithFormat:@"%ldh %ldm",
            (long)(whole / 3600), (long)((whole % 3600) / 60)];
}

- (void)updateProgress:(NSTimer *)timer {
    (void)timer;

    NSTimeInterval elapsed = self.startedAt ? -self.startedAt.timeIntervalSinceNow : 0.0;
    NSString *raw = [NSString stringWithContentsOfFile:self.progressPath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];

    if (raw.length == 0) {
        NSString *line = [NSString stringWithFormat:@"Preparing... %@", [self formatSeconds:elapsed]];
        if (elapsed > 5.0) {
            line = [line stringByAppendingString:@"   —   Large files or folders may take 30 seconds or more to begin."];
        }
        self.detailLabel.stringValue = line;
        return;
    }

    NSArray<NSString *> *tokens = [self tokensFromProgressText:raw];
    if (tokens.count < 2) {
        return;
    }

    unsigned long long done = tokens[0].unsignedLongLongValue;
    unsigned long long total = tokens[1].unsignedLongLongValue;
    if (total == 0) {
        return;
    }

    if (!self.encodingStartedAt) {
        self.encodingStartedAt = [NSDate date];
    }

    NSTimeInterval encodingElapsed = -self.encodingStartedAt.timeIntervalSinceNow;
    double percent = ((double)done / (double)total) * 100.0;
    percent = MIN(100.0, MAX(0.0, percent));
    self.progressBar.doubleValue = percent;

    double doneMB = (double)done / 1000000.0;
    double totalMB = (double)total / 1000000.0;
    double speed = encodingElapsed > 0.0 ? doneMB / encodingElapsed : 0.0;

    NSMutableString *line = [NSMutableString stringWithFormat:
                             @"%.0f%% complete   —   %.1f of %.1f MB   —   Time: %@",
                             percent, doneMB, totalMB, [self formatSeconds:elapsed]];

    if (speed > 0.0) {
        [line appendFormat:@"   —   %.1f MB/s", speed];
    }

    if (done > 0 && speed > 0.0) {
        double eta = MAX(0.0, (totalMB - doneMB) / speed);
        [line appendFormat:@"   —   ETA: %@", [self formatSeconds:eta]];
    } else {
        [line appendString:@"   —   ETA: estimating..."];
    }

    self.detailLabel.stringValue = line;
}

- (void)compressionTaskFinished:(NSTask *)finishedTask {
    [self.timer invalidate];
    self.timer = nil;

    [self.outputHandle closeFile];
    self.outputHandle = nil;
    self.task = nil;

    self.progressBar.doubleValue = 100.0;
    self.detailLabel.stringValue = @"Finishing...";
    [self.progressWindow displayIfNeeded];

    NSString *captured = [NSString stringWithContentsOfFile:self.outputPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil] ?: @"";
    captured = [captured stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];

    int status = finishedTask.terminationStatus;

    [[NSFileManager defaultManager] removeItemAtPath:self.progressPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:self.outputPath error:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self acceptFinishedResult:captured terminationStatus:status];
    });
}

- (BOOL)chooseReplacementDestinationForFailure:(NSString *)failureText {
    BOOL diskFull = [failureText rangeOfString:@"No space left on device"
                                       options:NSCaseInsensitiveSearch].location != NSNotFound;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = diskFull ? @"Your disk is full" : @"Choose a Destination";

    if (diskFull) {
        alert.informativeText = [NSString stringWithFormat:
            @"The save failed because this disk has no space left. Choose a folder on an external drive or quit.\n\n%@",
            failureText];
        [alert addButtonWithTitle:@"Choose External Folder"];
        [alert addButtonWithTitle:@"Quit"];

        if ([alert runModal] != NSAlertFirstButtonReturn) {
            return NO;
        }
    } else {
        alert.informativeText = [NSString stringWithFormat:
            @"MDLBSG could not save to that folder. Pick a destination to retry.\n\n%@",
            failureText];
        [alert addButtonWithTitle:@"Always Save Here"];
        [alert addButtonWithTitle:@"Just This Once"];
        [alert addButtonWithTitle:@"Quit"];

        NSInteger answer = [alert runModal];
        if (answer == NSAlertThirdButtonReturn) {
            return NO;
        }

        BOOL remember = answer == NSAlertFirstButtonReturn;

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseDirectories = YES;
        panel.canChooseFiles = NO;
        panel.allowsMultipleSelection = NO;
        panel.canCreateDirectories = YES;
        panel.prompt = @"Choose";
        panel.message = @"Choose where MDLBSG should save its output.";

        if ([panel runModal] != NSModalResponseOK || panel.URL.path.length == 0) {
            return NO;
        }

        self.destination = panel.URL.path;

        if (remember) {
            NSString *destFile = [MDLRoot() stringByAppendingPathComponent:@"destdir"];
            [self.destination writeToFile:destFile
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:nil];
        }
        return YES;
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = YES;
    panel.prompt = @"Choose";
    panel.message = @"Choose a folder on an external drive.";

    if ([panel runModal] != NSModalResponseOK || panel.URL.path.length == 0) {
        return NO;
    }

    self.destination = panel.URL.path;
    return YES;
}

- (void)acceptFinishedResult:(NSString *)captured terminationStatus:(int)status {
    NSString *input = self.inputPaths[(NSUInteger)self.currentIndex];
    NSString *name = [self displayNameForPath:input];

    if (self.cancelled) {
        [self.resultLines addObject:[NSString stringWithFormat:@"Cancelled: %@", name]];
        [self finishAllItems];
        return;
    }

    if ([captured hasPrefix:@"SAVE_FAILED"]) {
        if ([self chooseReplacementDestinationForFailure:captured]) {
            [self startCurrentItem];
        } else {
            [self.resultLines addObject:@"Cancelled."];
            self.currentIndex += 1;
            [self startCurrentItem];
        }
        return;
    }

    if (captured.length > 0) {
        [self.resultLines addObject:captured];
    } else if (status != 0) {
        [self.resultLines addObject:[NSString stringWithFormat:
                                     @"Compression failed for %@ with status %d.", name, status]];
    } else {
        [self.resultLines addObject:[NSString stringWithFormat:@"Finished: %@", name]];
    }

    self.currentIndex += 1;
    [self startCurrentItem];
}

- (void)stopPressed:(id)sender {
    (void)sender;
    if (self.cancelled) {
        return;
    }

    self.cancelled = YES;
    self.stopButton.enabled = NO;
    self.detailLabel.stringValue = @"Stopping...";

    pid_t pid = self.task ? self.task.processIdentifier : 0;
    if (pid <= 0) {
        [self finishAllItems];
        return;
    }

    NSTask *childKill = [[NSTask alloc] init];
    childKill.launchPath = @"/usr/bin/pkill";
    childKill.arguments = @[@"-TERM", @"-P", [NSString stringWithFormat:@"%d", pid]];
    childKill.standardOutput = [NSPipe pipe];
    childKill.standardError = [NSPipe pipe];

    @try {
        [childKill launch];
        [childKill waitUntilExit];
    } @catch (NSException *exception) {
        (void)exception;
    }

    kill(pid, SIGTERM);

    __weak MDLApp85Wrapper *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MDLApp85Wrapper *strongSelf = weakSelf;
        if (strongSelf.task.isRunning) {
            pid_t stillRunning = strongSelf.task.processIdentifier;
            if (stillRunning > 0) {
                NSTask *hardChildKill = [[NSTask alloc] init];
                hardChildKill.launchPath = @"/usr/bin/pkill";
                hardChildKill.arguments = @[@"-KILL", @"-P",
                                            [NSString stringWithFormat:@"%d", stillRunning]];
                hardChildKill.standardOutput = [NSPipe pipe];
                hardChildKill.standardError = [NSPipe pipe];
                @try {
                    [hardChildKill launch];
                    [hardChildKill waitUntilExit];
                } @catch (NSException *exception) {
                    (void)exception;
                }
                kill(stillRunning, SIGKILL);
            }
        }
    });
}

- (BOOL)launchDetachedResults:(NSString *)summary {
    NSString *resultPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"mdlbsg_res_%@", NSUUID.UUID.UUIDString]];

    if (![summary writeToFile:resultPath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil]) {
        return NO;
    }

    NSString *launcher = [MDLRoot() stringByAppendingPathComponent:@"bin/mdlbsg_detached_spawn"];
    NSString *dialog = [MDLRoot() stringByAppendingPathComponent:@"results_dialog.applescript"];

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:launcher] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:dialog]) {
        return NO;
    }

    NSTask *spawn = [[NSTask alloc] init];
    spawn.launchPath = launcher;
    spawn.arguments = @[@"/usr/bin/osascript", dialog, resultPath];
    spawn.standardOutput = [NSPipe pipe];
    spawn.standardError = [NSPipe pipe];

    @try {
        [spawn launch];
        [spawn waitUntilExit];
        return spawn.terminationStatus == 0;
    } @catch (NSException *exception) {
        AppendLaunchLog([NSString stringWithFormat:@"app85-results-launch-error %@",
                         exception.reason ?: @"unknown"]);
        return NO;
    }
}

- (void)finishAllItems {
    [self.timer invalidate];
    self.timer = nil;
    self.stopButton.enabled = NO;
    self.progressBar.doubleValue = 100.0;
    self.detailLabel.stringValue = @"Complete.";
    [self.progressWindow displayIfNeeded];

    NSString *summary = [self.resultLines componentsJoinedByString:@"\n\n"];
    if (summary.length == 0) {
        summary = self.cancelled ? @"Cancelled." : @"Finished.";
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.progressWindow orderOut:nil];
        [self.progressWindow close];
        self.progressWindow = nil;

        AppendLaunchLog(@"app85-progress-window-closed-before-results");

        if (![self launchDetachedResults:summary]) {
            NSAlert *fallback = [[NSAlert alloc] init];
            fallback.messageText = @"MDLBSG Compressor";
            fallback.informativeText = summary;
            [fallback addButtonWithTitle:@"OK"];
            [NSApp activateIgnoringOtherApps:YES];
            [fallback runModal];
        }

        AppendLaunchLog(@"app85-wrapper-complete");
        [NSApp terminate:nil];
    });
}

@end

static int RunSelfTest(void) {
    @autoreleasepool {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"mdlbsg_app85_selftest_%@", NSUUID.UUID.UUIDString]];

        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/bin/sh";
        task.arguments = @[@"-c", [NSString stringWithFormat:@"printf app85-ok > '%@'", path]];

        @try {
            [task launch];
            [task waitUntilExit];
        } @catch (NSException *exception) {
            fprintf(stderr, "self-test launch failed: %s\n", exception.reason.UTF8String);
            return 1;
        }

        NSString *value = [NSString stringWithContentsOfFile:path
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

        if (![value isEqualToString:@"app85-ok"]) {
            fprintf(stderr, "self-test output mismatch\n");
            return 1;
        }

        printf("MDLBSG_APP85_WRAPPER_SELF_TEST_PASS\n");
        return 0;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
            return RunSelfTest();
        }

        NSString *destination = nil;
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        BOOL readingPaths = NO;

        for (int i = 1; i < argc; ++i) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];

            if (!readingPaths && [arg isEqualToString:@"--dest"] && i + 1 < argc) {
                destination = [NSString stringWithUTF8String:argv[++i]];
                continue;
            }

            if ([arg isEqualToString:@"--"]) {
                readingPaths = YES;
                continue;
            }

            [paths addObject:arg];
        }

        if (destination.length == 0 || paths.count == 0) {
            fprintf(stderr, "usage: mdlbsg_app85_wrapper --dest folder -- path [path...]\n");
            return 64;
        }

        NSApplication *application = [NSApplication sharedApplication];
        MDLApp85Wrapper *delegate = [[MDLApp85Wrapper alloc] initWithPaths:paths
                                                               destination:destination];
        application.delegate = delegate;
        [application run];
        return 0;
    }
}
OBJC

cat > "$APPLESCRIPT_SOURCE" <<'APPLESCRIPT'
-- MDLBSG Compressor App 85
-- MDLBSG_APP85_FRESH_CONDITIONAL_WRAPPER
-- Compressor core untouched. Built-in AppleScript progress removed completely.
use AppleScript version "2.4"
use scripting additions

property mdlbsgApp85ProofMarker : "MDLBSG_APP85_FRESH_CONDITIONAL_WRAPPER"
property sessionDest : ""

on logLaunch(tag)
	try
		do shell script "mkdir -p ~/.mdlbsg && echo \"$(date '+%Y-%m-%d %H:%M:%S') " & tag & "\" >> ~/.mdlbsg/launch.log"
	end try
end logLaunch

on closeMenuHelper()
	set killPattern to "^/usr/bin/osascript .*[/]launcher_dialog[.]applescript"
	try
		do shell script "/usr/bin/pkill -f " & quoted form of killPattern & " >/dev/null 2>&1 || true"
	end try
end closeMenuHelper

on launchMenuHelper()
	my closeMenuHelper()
	set homePath to POSIX path of (path to home folder)
	set helperPath to homePath & ".mdlbsg/launcher_dialog.applescript"
	set detachedLauncher to homePath & ".mdlbsg/bin/mdlbsg_detached_spawn"
	try
		do shell script "test -x " & quoted form of detachedLauncher & " && test -f " & quoted form of helperPath
		do shell script quoted form of detachedLauncher & " /usr/bin/osascript " & quoted form of helperPath
		my logLaunch("app85 detached menu helper")
	on error errMsg number errNum
		my logLaunch("app85 menu-helper error " & (errNum as text) & " " & errMsg)
	end try
end launchMenuHelper

on run
	my logLaunch("app85 run-handler -> detached menu helper")
	my launchMenuHelper()
end run

on reopen
	my logLaunch("app85 reopen-handler -> detached menu helper")
	my launchMenuHelper()
end reopen

on resolveDest()
	set saved to ""
	try
		set saved to do shell script "cat ~/.mdlbsg/destdir 2>/dev/null"
	end try
	if saved is not "" then
		set my sessionDest to saved
		return true
	end if
	return my pickDestDialog()
end resolveDest

on pickDestDialog()
	activate
	try
		set chosenFolder to POSIX path of (choose folder with prompt "Where should MDLBSG save its output?" default location (path to downloads folder))
	on error number -128
		return false
	end try

	set my sessionDest to chosenFolder

	try
		activate
		set dlg to display dialog "Save to this folder every time?" & return & return & chosenFolder & return & return & "(Change it anytime — every results window has a Save Folder... button.)" with title "Save Location" buttons {"Just This Once", "Always Save Here"} default button "Always Save Here" with icon note
		if button returned of dlg is "Always Save Here" then
			do shell script "mkdir -p ~/.mdlbsg && printf '%s' " & quoted form of chosenFolder & " > ~/.mdlbsg/destdir"
		else
			do shell script "rm -f ~/.mdlbsg/destdir"
		end if
	on error number -128
		return false
	end try

	return true
end pickDestDialog

on dispatchToFreshWrapper(theFiles)
	if not my resolveDest() then return false

	set homePath to POSIX path of (path to home folder)
	set detachedLauncher to homePath & ".mdlbsg/bin/mdlbsg_detached_spawn"
	set wrapperPath to homePath & ".mdlbsg/bin/mdlbsg_app85_wrapper"

	do shell script "test -x " & quoted form of detachedLauncher & " && test -x " & quoted form of wrapperPath

	set cmd to quoted form of detachedLauncher & " " & quoted form of wrapperPath & " --dest " & quoted form of my sessionDest & " --"

	repeat with droppedItem in theFiles
		set cmd to cmd & " " & quoted form of (POSIX path of droppedItem)
	end repeat

	do shell script cmd
	my logLaunch("app85 dispatched fresh conditional wrapper items=" & ((count of theFiles) as text))
	return true
end dispatchToFreshWrapper

on open theFiles
	my logLaunch("app85 open-handler items=" & ((count of theFiles) as text))
	my closeMenuHelper()

	if (count of theFiles) is 0 then
		my launchMenuHelper()
		return
	end if

	try
		my dispatchToFreshWrapper(theFiles)
	on error errMsg number errNum
		my logLaunch("app85 dispatch error " & (errNum as text) & " " & errMsg)
		activate
		display dialog "MDLBSG could not start the fresh progress wrapper." & return & return & errMsg with title "MDLBSG Compressor" buttons {"OK"} default button "OK" with icon caution
	end try
end open
APPLESCRIPT

echo "[1/7] compiling the fresh native wrapper..."

/usr/bin/clang \
  -fobjc-arc \
  -O2 \
  -Wall \
  -Wextra \
  -framework Cocoa \
  "$WRAPPER_SOURCE" \
  -o "$WRAPPER_BUILD" \
  || fail "the fresh native wrapper did not compile"

chmod +x "$WRAPPER_BUILD"
SELFTEST_OUTPUT="$("$WRAPPER_BUILD" --self-test)" \
  || fail "the fresh wrapper self-test failed"

case "$SELFTEST_OUTPUT" in
  *MDLBSG_APP85_WRAPPER_SELF_TEST_PASS*) ;;
  *) fail "the fresh wrapper self-test returned unexpected output" ;;
esac

echo "      native compile: PASS"
echo "      process self-test: PASS"

echo
 echo "[2/7] proving the new AppleScript droplet owns no progress window..."

grep -Fq "MDLBSG_APP85_FRESH_CONDITIONAL_WRAPPER" "$APPLESCRIPT_SOURCE" \
  || fail "App 85 source marker is missing"
grep -Fq "mdlbsg_app85_wrapper" "$APPLESCRIPT_SOURCE" \
  || fail "App 85 source does not dispatch the fresh wrapper"

if grep -Eiq 'set[[:space:]]+progress|progress[[:space:]]+total[[:space:]]+steps|progress[[:space:]]+completed[[:space:]]+steps' "$APPLESCRIPT_SOURCE"; then
  fail "App 85 droplet still contains AppleScript built-in progress logic"
fi

echo "      built-in AppleScript progress commands: ZERO"

echo
 echo "[3/7] compiling a clean App 85 Compressor bundle..."

/usr/bin/osacompile -o "$STAGE_APP" "$APPLESCRIPT_SOURCE" \
  || fail "osacompile failed for the fresh App 85 droplet"

PLIST="$STAGE_APP/Contents/Info.plist"
MAIN="$STAGE_APP/Contents/Resources/Scripts/main.scpt"
PB="/usr/libexec/PlistBuddy"

[ -f "$PLIST" ] || fail "staged App 85 Info.plist is missing"
[ -f "$MAIN" ] || fail "staged App 85 main.scpt is missing"

set_string() {
  local key="$1"
  local value="$2"
  "$PB" -c "Set :$key $value" "$PLIST" >/dev/null 2>&1 \
    || "$PB" -c "Add :$key string $value" "$PLIST" >/dev/null
}

set_string "CFBundleIdentifier" "com.mdlbsg.compressor"
set_string "CFBundleName" "MDLBSG Compressor"
set_string "CFBundleDisplayName" "MDLBSG Compressor"
set_string "CFBundleShortVersionString" "85"
set_string "CFBundleVersion" "85"

"$PB" -c "Delete :OSAAppletStayOpen" "$PLIST" >/dev/null 2>&1 || true
"$PB" -c "Set :OSAAppletShowStartupScreen false" "$PLIST" >/dev/null 2>&1 \
  || "$PB" -c "Add :OSAAppletShowStartupScreen bool false" "$PLIST" >/dev/null

OLD_ICON="$(find "$APP/Contents/Resources" -maxdepth 1 -type f -name '*.icns' -print -quit 2>/dev/null || true)"
NEW_ICON="$(find "$STAGE_APP/Contents/Resources" -maxdepth 1 -type f -name '*.icns' -print -quit 2>/dev/null || true)"
if [ -n "$OLD_ICON" ] && [ -n "$NEW_ICON" ]; then
  cp "$OLD_ICON" "$NEW_ICON"
fi

/usr/bin/osadecompile "$MAIN" > "$PROOF_TEXT" \
  || fail "osadecompile failed for staged App 85"

grep -Fq "MDLBSG_APP85_FRESH_CONDITIONAL_WRAPPER" "$PROOF_TEXT" \
  || fail "staged App 85 lost its proof marker"
grep -Fq "mdlbsg_app85_wrapper" "$PROOF_TEXT" \
  || fail "staged App 85 lost the wrapper dispatch"

if grep -Eiq 'set[[:space:]]+progress|progress[[:space:]]+total[[:space:]]+steps|progress[[:space:]]+completed[[:space:]]+steps' "$PROOF_TEXT"; then
  fail "compiled App 85 still contains AppleScript built-in progress logic"
fi

EXECUTABLE="$("$PB" -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || true)"
[ "$EXECUTABLE" = "droplet" ] || fail "expected staged executable droplet, got: $EXECUTABLE"

echo "      staged marker: PASS"
echo "      staged wrapper dispatch: PASS"
echo "      staged built-in progress commands: ZERO"
echo "      staged executable: droplet"

echo
 echo "[4/7] signing and verifying the staged app..."

xattr -cr "$STAGE_APP" 2>/dev/null || true
chmod a-w "$MAIN" 2>/dev/null || true
/usr/bin/codesign --force --sign - "$STAGE_APP" \
  || fail "codesign failed on staged App 85"
/usr/bin/codesign --verify --strict "$STAGE_APP" \
  || fail "signature verification failed on staged App 85"

echo "      staged signature: PASS"

echo
 echo "[5/7] stopping only the old Compressor wrapper processes..."

pkill -TERM -f '^/usr/bin/osascript .*[/]launcher_dialog[.]applescript' 2>/dev/null || true

for executable in droplet applet
do
  pkill -TERM -f "/MDLBSG Compressor.app/Contents/MacOS/${executable}" 2>/dev/null || true
done

pkill -TERM -f "$BIN/mdlbsg_job_controller" 2>/dev/null || true
pkill -TERM -f "$BIN/mdlbsg_app85_wrapper" 2>/dev/null || true

sleep 2

for executable in droplet applet
do
  pattern="/MDLBSG Compressor.app/Contents/MacOS/${executable}"
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    pkill -KILL -f "$pattern" 2>/dev/null || true
  fi
done

pkill -KILL -f "$BIN/mdlbsg_job_controller" 2>/dev/null || true
pkill -KILL -f "$BIN/mdlbsg_app85_wrapper" 2>/dev/null || true
sleep 1

for executable in droplet applet
do
  pattern="/MDLBSG Compressor.app/Contents/MacOS/${executable}"
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    fail "an old Compressor process survived: $pattern"
  fi
done

echo "      old Compressor wrapper processes: STOPPED"

echo
 echo "[6/7] installing App 85 while preserving the compressor core..."

BACKUP="$HOME/Downloads/MDLBSG_Compressor_before_App85_${STAMP}.app"
cp -R "$APP" "$BACKUP" \
  || fail "could not back up the current Compressor app"

cp "$WRAPPER_BUILD" "$BIN/mdlbsg_app85_wrapper"
chmod +x "$BIN/mdlbsg_app85_wrapper"
cp "$WRAPPER_SOURCE" "$SRCROOT/mdlbsg_app85_wrapper.m"
cp "$APPLESCRIPT_SOURCE" "$SRCROOT/MDLBSG_Compressor_App85.applescript"

rm -f "$BIN/mdlbsg_job_controller" "$BIN/BUILD_INFO_APP83" 2>/dev/null || true

rm -rf "$APP"
mv "$STAGE_APP" "$APP"

INSTALLED_MAIN="$APP/Contents/Resources/Scripts/main.scpt"
INSTALLED_PLIST="$APP/Contents/Info.plist"
INSTALLED_PROOF="$WORK/installed_app85.decompiled.applescript"

[ -f "$INSTALLED_MAIN" ] || fail "installed App 85 main.scpt is missing"
/usr/bin/osadecompile "$INSTALLED_MAIN" > "$INSTALLED_PROOF" \
  || fail "installed App 85 could not be decompiled"

grep -Fq "MDLBSG_APP85_FRESH_CONDITIONAL_WRAPPER" "$INSTALLED_PROOF" \
  || fail "installed App 85 lost its proof marker"
grep -Fq "mdlbsg_app85_wrapper" "$INSTALLED_PROOF" \
  || fail "installed App 85 lost the fresh wrapper dispatch"

if grep -Eiq 'set[[:space:]]+progress|progress[[:space:]]+total[[:space:]]+steps|progress[[:space:]]+completed[[:space:]]+steps' "$INSTALLED_PROOF"; then
  fail "installed App 85 contains forbidden built-in progress logic"
fi

INSTALLED_VERSION="$("$PB" -c 'Print :CFBundleVersion' "$INSTALLED_PLIST" 2>/dev/null || true)"
INSTALLED_EXEC="$("$PB" -c 'Print :CFBundleExecutable' "$INSTALLED_PLIST" 2>/dev/null || true)"

[ "$INSTALLED_VERSION" = "85" ] || fail "installed bundle version is not 85"
[ "$INSTALLED_EXEC" = "droplet" ] || fail "installed executable is not droplet"
[ -x "$BIN/mdlbsg_app85_wrapper" ] || fail "installed native wrapper is not executable"

/usr/bin/codesign --verify --strict "$APP" \
  || fail "installed App 85 signature verification failed"

echo "      backup created: $BACKUP"
echo "      compressor core handler unchanged: $HANDLER"
echo "      installed bundle version: 85"
echo "      installed executable: droplet"
echo "      installed built-in progress commands: ZERO"
echo "      installed fresh wrapper: PASS"
echo "      installed signature: PASS"

echo
 echo "[7/7] refreshing Launch Services..."

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi
killall Finder >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

cat > "$BIN/BUILD_INFO_APP85" <<EOF
built: $(date '+%Y-%m-%d %H:%M:%S')
version: App 85 fresh conditional wrapper
compressor_core_changed: NO
archive_format_changed: NO
decompressor_changed: NO
progress_owner: native App 85 wrapper
completion_condition: compressor process exited and result captured
handoff_order: set 100 percent -> close progress window -> launch stats popup
apple_script_builtin_progress_commands: ZERO
compressor_bundle: $APP
backup_bundle: $BACKUP
wrapper_self_test: PASS
EOF

echo
echo "============================================================"
echo "APP 85 FRESH WRAPPER INSTALLED"
echo "============================================================"
echo
echo "The workflow is unchanged:"
echo "  1. Drag a file or folder onto MDLBSG Compressor."
echo "  2. One progress window opens."
echo "  3. The existing compressor runs unchanged."
echo "  4. Real process completion sets the bar to 100%."
echo "  5. The progress window closes."
echo "  6. Only then does the statistics popup open."
echo
echo "The Decompressor and compression algorithm were not rebuilt or changed."
echo