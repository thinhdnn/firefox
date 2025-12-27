/* -*- Mode: c++; tab-width: 2; indent-tabs-mode: nil; -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#include "nsStatusBarMenu.h"
#include "nsObjCExceptions.h"
#include "nsAppRunner.h"
#include "nsCOMPtr.h"
#include "nsServiceManagerUtils.h"
#include "nsINativeAppSupport.h"
#include "nsIWindowMediator.h"
#include "nsISimpleEnumerator.h"
#include "nsIAppWindow.h"
#include "nsIBaseWindow.h"
#include "nsError.h"
#include "nsIWidget.h"

#import <CommonCrypto/CommonDigest.h>

namespace {

static NSString* const kStatusBarPasswordDefaultsKey =
    @"StatusBarModePasswordHash";

static bool sRequirePasswordOnNextShow = false;

static NSString* HashForPassword(NSString* aPassword) {
  if (!aPassword) {
    return @"";
  }

  NSData* data = [aPassword dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256((const unsigned char*)[data bytes], (CC_LONG)[data length],
            digest);

  NSMutableString* hex = [NSMutableString
      stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
    [hex appendFormat:@"%02x", digest[i]];
  }
  return hex;
}

static void StorePasswordHash(NSString* aHash) {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  if (aHash && [aHash length] > 0) {
    [defaults setObject:aHash forKey:kStatusBarPasswordDefaultsKey];
  } else {
    [defaults removeObjectForKey:kStatusBarPasswordDefaultsKey];
  }
  [defaults synchronize];
}

static bool PasswordIsConfigured() {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSString* hash =
      [defaults stringForKey:kStatusBarPasswordDefaultsKey];
  return hash && [hash length] > 0;
}

static bool VerifyPasswordValue(NSString* aPassword) {
  if (!PasswordIsConfigured()) {
    return true;
  }

  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSString* storedHash =
      [defaults stringForKey:kStatusBarPasswordDefaultsKey];
  return storedHash &&
         [storedHash isEqualToString:HashForPassword(aPassword ?: @"")];
}

static bool ShowCocoaWindow(NSWindow* aWindow) {
  if (!aWindow) {
    return false;
  }

  [aWindow setIsVisible:YES];
  [aWindow deminiaturize:nil];
  [aWindow makeKeyAndOrderFront:nil];
  [aWindow orderFrontRegardless];
  return true;
}

static NSWindow* CocoaWindowForAppWindow(nsIAppWindow* aAppWindow) {
  if (!aAppWindow) {
    return nil;
  }

  nsCOMPtr<nsIBaseWindow> baseWindow = do_QueryInterface(aAppWindow);
  if (!baseWindow) {
    return nil;
  }

  nsCOMPtr<nsIWidget> widget;
  baseWindow->GetMainWidget(getter_AddRefs(widget));
  if (!widget) {
    return nil;
  }

  return (NSWindow*)widget->GetNativeData(NS_NATIVE_WINDOW);
}

static bool RestoreViaWindowMediator() {
  nsCOMPtr<nsIWindowMediator> windowMediator =
      do_GetService(NS_WINDOWMEDIATOR_CONTRACTID);
  if (!windowMediator) {
    printf("🦊 Window mediator unavailable\n");
    return false;
  }

  auto BringWindowsForType = [&](const char16_t* aType) {
    bool restored = false;
    nsCOMPtr<nsISimpleEnumerator> enumerator;
    windowMediator->GetZOrderAppWindowEnumerator(aType, /* aFrontToBack */ true,
                                                 getter_AddRefs(enumerator));
    bool hasMore = false;
    while (enumerator &&
           NS_SUCCEEDED(enumerator->HasMoreElements(&hasMore)) && hasMore) {
      nsCOMPtr<nsISupports> nextWindow;
      enumerator->GetNext(getter_AddRefs(nextWindow));
      nsCOMPtr<nsIAppWindow> appWindow = do_QueryInterface(nextWindow);
      if (!appWindow) {
        continue;
      }

      if (ShowCocoaWindow(CocoaWindowForAppWindow(appWindow))) {
        restored = true;
      }
    }
    return restored;
  };

  // Prioritize browser windows, fall back to any top-level window.
  if (BringWindowsForType(u"navigator:browser")) {
    return true;
  }

  return BringWindowsForType(nullptr);
}

static bool RestoreFirefoxWindows() {
  // Prefer restoring already-existing windows via the mediator first so we do
  // not accidentally spawn a fresh session when real windows still exist.
  if (RestoreViaWindowMediator()) {
    return true;
  }

  // If the mediator could not find anything (for example after the user
  // intentionally closed every window), fall back to the native ReOpen() logic
  // so they still get a new browser window instead of nothing happening.
  nsCOMPtr<nsINativeAppSupport> nativeSupport = NS_GetNativeAppSupport();
  if (nativeSupport) {
    nativeSupport->ReOpen();
    return true;
  }

  return false;
}

}  // namespace

@interface MOZStatusBarTarget ()
- (BOOL)isBrowserWindow:(NSWindow*)window;
@end

// MOZStatusBarTarget implementation
@implementation MOZStatusBarTarget

- (id)initWithStatusBarMenu:(nsStatusBarMenu*)aStatusBarMenu {
  if ((self = [super init])) {
    mStatusBarMenu = aStatusBarMenu;
  }
  return self;
}

- (void)menuItemClicked:(id)sender {
  if (mStatusBarMenu) {
    mStatusBarMenu->MenuItemClicked((NSMenuItem*)sender);
  }
}

- (void)showMainWindow:(id)sender {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  if (PasswordIsConfigured() && sRequirePasswordOnNextShow) {
    if (![self promptForPassword]) {
      printf("🦊 Password verification failed or cancelled\n");
      return;
    }
    sRequirePasswordOnNextShow = false;
  }

  printf("🦊 Show Firefox clicked\n");
  
  // Count existing windows first
  int windowCount = 0;
  NSWindow* browserWindow = nil;
  for (NSWindow* window in [NSApp windows]) {
    if (window.contentView != nil) {
      windowCount++;
      NSSize frameSize = window.frame.size;
      printf("🦊 Existing window: %s (visible: %s, frame: %.0fx%.0f)\n", 
             [window.className UTF8String], 
             [window isVisible] ? "YES" : "NO",
             frameSize.width, frameSize.height);

      [self attachCloseButtonHandlerToWindow:window];
      
      // Try to identify the main browser window
      if ([window.className isEqualToString:@"NSWindow"] || 
          [window.className isEqualToString:@"BorderlessWindow"] ||
          [window.className isEqualToString:@"ToolbarWindow"]) {
        printf("🦊 Checking potential browser window: %s, size: %.0fx%.0f\n", 
               [window.className UTF8String], frameSize.width, frameSize.height);
        
        if (frameSize.width > 400 && frameSize.height > 300) {
          browserWindow = window;
          printf("🦊 ✅ Identified browser window: %s (%.0fx%.0f)\n", 
                 [window.className UTF8String], frameSize.width, frameSize.height);
        } else {
          printf("🦊 ❌ Window too small: %s (%.0fx%.0f)\n", 
                 [window.className UTF8String], frameSize.width, frameSize.height);
        }
      }
    }
  }
  printf("🦊 Total windows found: %d\n", windowCount);
  
  // If we have a browser window, try to show it directly first
  if (browserWindow) {
    printf("🦊 Attempting to show existing browser window\n");
    [self attachCloseButtonHandlerToWindow:browserWindow];
    [browserWindow setIsVisible:YES];
    [browserWindow makeKeyAndOrderFront:nil];
    [browserWindow orderFrontRegardless];
    [browserWindow deminiaturize:nil];
    
    // Activate app after showing window
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSRunningApplication* currentApp = [NSRunningApplication currentApplication];
      [currentApp activateWithOptions:NSApplicationActivateAllWindows |
                                     NSApplicationActivateIgnoringOtherApps];
    });
    
    printf("🦊 Direct window restore completed\n");
    return; // Skip Gecko restore to avoid conflicts
  }
  
  // Try Gecko restore only if no existing browser window
  printf("🦊 No browser window found, trying Gecko restore\n");
  bool restoredByGecko = RestoreFirefoxWindows();
  if (restoredByGecko) {
    printf("🦊 Restored windows via Gecko window mediator\n");
    // Activate app to bring windows forward, but avoid policy conflicts
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSRunningApplication* currentApp = [NSRunningApplication currentApplication];
      [currentApp activateWithOptions:NSApplicationActivateAllWindows |
                                     NSApplicationActivateIgnoringOtherApps];
    });

    // Ensure newly created windows get close-button interceptors
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self attachCloseButtonHandlersToAllWindows];
    });
  } else {
    printf("🦊 Gecko restore failed, no fallback available\n");
  }
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

- (void)quitApplication:(id)sender {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  [NSApp terminate:nil];
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

- (void)hideToStatusBar:(id)sender {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  printf("🦊 Hide to status bar clicked\n");
  
  // Hide the entire app (windows stay alive, preserving session state)
  [[NSRunningApplication currentApplication] hide];
  [NSApp hide:nil];
  printf("🦊 Application hidden via NSApp hide\n");

  // Ensure activation policy stays in accessory mode for status-bar presence
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  printf("🦊 Confirmed activation policy Accessory after hide\n");
  if (PasswordIsConfigured()) {
    sRequirePasswordOnNextShow = true;
  }
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

- (BOOL)promptForPassword {
  while (true) {
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Enter password to show Firefox"];
    [alert setInformativeText:@"Firefox is hidden and requires your password before restoring windows."];
    [alert addButtonWithTitle:@"Unlock"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView* accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 30)];
    NSSecureTextField* passwordField =
        [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    [passwordField setPlaceholderString:@"Password"];
    [accessory addSubview:passwordField];
    [alert setAccessoryView:accessory];

    NSModalResponse response = [alert runModal];

    NSString* input = [[passwordField stringValue] copy];

    [passwordField release];
    [accessory release];
    [alert release];

    if (response != NSAlertFirstButtonReturn) {
      [input release];
      return NO;
    }

    bool verified = VerifyPasswordValue(input);
    [input release];
    if (verified) {
      return YES;
    }

    NSAlert* errorAlert = [[NSAlert alloc] init];
    [errorAlert setMessageText:@"Incorrect password"];
    [errorAlert setInformativeText:@"Please try again."];
    [errorAlert addButtonWithTitle:@"OK"];
    [errorAlert runModal];
    [errorAlert release];
  }
}

- (void)setPassword:(id)sender {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  NSAlert* alert = [[NSAlert alloc] init];
  [alert setMessageText:@"Set password"];
  [alert setInformativeText:@"Enter and confirm the password required before Firefox windows can be shown again."];
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Cancel"];

  NSView* accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 64)];
  NSSecureTextField* newField =
      [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 32, 280, 24)];
  [newField setPlaceholderString:@"New password"];
  NSSecureTextField* confirmField =
      [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
  [confirmField setPlaceholderString:@"Confirm password"];
  [accessory addSubview:newField];
  [accessory addSubview:confirmField];
  [alert setAccessoryView:accessory];

  NSModalResponse response = [alert runModal];

  NSString* newPassword = [[newField stringValue] copy];
  NSString* confirmPassword = [[confirmField stringValue] copy];

  [newField release];
  [confirmField release];
  [accessory release];
      // Make sure the app is unhidden before toggling visibility so AppKit keeps
      // the window hierarchy alive without forcing Dock presence.
      [[NSRunningApplication currentApplication] unhide];
      [NSApp unhide:nil];

  [alert release];

  if (response != NSAlertFirstButtonReturn) {
    [newPassword release];
    [confirmPassword release];
    return;
  }

  if (![newPassword length]) {
    NSAlert* errorAlert = [[NSAlert alloc] init];
    [errorAlert setMessageText:@"Password required"];
    [errorAlert setInformativeText:@"Please enter a non-empty password."];
    [errorAlert addButtonWithTitle:@"OK"];
    [errorAlert runModal];
    [errorAlert release];
    [newPassword release];
    [confirmPassword release];
    return;
  }

  if (![newPassword isEqualToString:confirmPassword]) {
    NSAlert* mismatchAlert = [[NSAlert alloc] init];
    [mismatchAlert setMessageText:@"Passwords do not match"];
    [mismatchAlert setInformativeText:@"Please try again."];
    [mismatchAlert addButtonWithTitle:@"OK"];
    [mismatchAlert runModal];
    [mismatchAlert release];
    [newPassword release];
    [confirmPassword release];
    return;
  }

  StorePasswordHash(HashForPassword(newPassword));
  sRequirePasswordOnNextShow = true;
  if (mStatusBarMenu) {
    mStatusBarMenu->UpdatePasswordMenuItems();
  }
  printf("🦊 Status bar password updated\n");

  [newPassword release];
  [confirmPassword release];

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

- (void)clearPassword:(id)sender {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  if (!PasswordIsConfigured()) {
    return;
  }

  NSAlert* alert = [[NSAlert alloc] init];
  [alert setMessageText:@"Clear password?"];
  [alert setInformativeText:@"Firefox will no longer ask for a password before showing windows."];
  [alert addButtonWithTitle:@"Clear"];
  [alert addButtonWithTitle:@"Cancel"];

  NSModalResponse response = [alert runModal];
  [alert release];

  if (response != NSAlertFirstButtonReturn) {
    return;
  }

  StorePasswordHash(@"");
  sRequirePasswordOnNextShow = false;
  if (mStatusBarMenu) {
    mStatusBarMenu->UpdatePasswordMenuItems();
  }
  printf("🦊 Status bar password cleared\n");

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

- (BOOL)isBrowserWindow:(NSWindow*)window {
  if (!window || window.contentView == nil) {
    return NO;
  }
  NSString* className = window.className;
  return [className isEqualToString:@"ToolbarWindow"] ||
         [className isEqualToString:@"NSWindow"] ||
         [className isEqualToString:@"BorderlessWindow"];
}

- (void)attachCloseButtonHandlerToWindow:(NSWindow*)window {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  if (![self isBrowserWindow:window]) {
    return;
  }

  NSButton* closeButton = [window standardWindowButton:NSWindowCloseButton];
  if (!closeButton) {
    return;
  }

  if ([closeButton target] == self &&
      [closeButton action] == @selector(handleWindowCloseButton:)) {
    return;
  }

  printf("🦊 Installing close-button interceptor for %s\n",
         [window.className UTF8String]);
  [closeButton setTarget:self];
  [closeButton setAction:@selector(handleWindowCloseButton:)];
  [closeButton setToolTip:@"Hide Firefox to the status bar"];

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

- (void)attachCloseButtonHandlersToAllWindows {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  for (NSWindow* window in [NSApp windows]) {
    [self attachCloseButtonHandlerToWindow:window];
  }

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

- (void)handleWindowCloseButton:(id)sender {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  NSWindow* window = [sender window];
  printf("🦊 Close button intercepted for window: %s\n",
         [window.className UTF8String]);
  [self hideToStatusBar:nil];

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

@end

// nsStatusBarMenu implementation
nsStatusBarMenu::nsStatusBarMenu()
    : mStatusItem(nullptr),
      mMenu(nullptr),
      mTarget(nullptr),
      mSetPasswordItem(nullptr),
      mClearPasswordItem(nullptr) {
}

nsStatusBarMenu::~nsStatusBarMenu() {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  if (mStatusItem) {
    [[NSStatusBar systemStatusBar] removeStatusItem:mStatusItem];
    [mStatusItem release];
    mStatusItem = nil;
  }
  
  if (mMenu) {
    [mMenu release];
    mMenu = nil;
  }

  if (mSetPasswordItem) {
    [mSetPasswordItem release];
    mSetPasswordItem = nil;
  }

  if (mClearPasswordItem) {
    [mClearPasswordItem release];
    mClearPasswordItem = nil;
  }
  
  if (mTarget) {
    [mTarget release];
    mTarget = nil;
  }
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

bool nsStatusBarMenu::Init() {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;

  if (!XRE_IsParentProcess()) {
    printf("🦊 nsStatusBarMenu::Init() blocked outside parent process\n");
    return false;
  }
  
  printf("🦊 nsStatusBarMenu::Init() called\n");
  
  // Create status bar item
  mStatusItem = [[[NSStatusBar systemStatusBar] 
                  statusItemWithLength:NSSquareStatusItemLength] retain];
  if (!mStatusItem) {
    printf("🦊 Failed to create status item\n");
    return false;
  }
  
  printf("🦊 Status item created\n");
  
  // Create target for menu actions
  mTarget = [[MOZStatusBarTarget alloc] initWithStatusBarMenu:this];
  if (!mTarget) {
    return false;
  }
  
  // Set default icon (Firefox icon)
  NSImage* icon = [NSApp applicationIconImage];
  if (icon) {
    // Resize icon to fit status bar (typically 16x16 or 18x18)
    NSImage* statusIcon = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [statusIcon lockFocus];
    [icon drawInRect:NSMakeRect(0, 0, 18, 18)
            fromRect:NSZeroRect
           operation:NSCompositeSourceOver
            fraction:1.0];
    [statusIcon unlockFocus];
    
    [mStatusItem setImage:statusIcon];
    [statusIcon release];
  } else {
    // Fallback to text if no icon
    [mStatusItem setTitle:@"🦊"];
  }
  
  // Build and set menu
  bool rv = BuildStatusMenu();
  if (!rv) {
    return false;
  }
  
  [mStatusItem setMenu:mMenu];
  [mStatusItem setHighlightMode:YES];
  
  // Install close-button interceptors on any existing windows
  [mTarget attachCloseButtonHandlersToAllWindows];
  
  return true;
  
  NS_OBJC_END_TRY_BLOCK_RETURN(false);
}

bool nsStatusBarMenu::BuildStatusMenu() {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;
  
  if (mMenu) {
    [mMenu release];
  }
  
  mMenu = [[NSMenu alloc] init];
  [mMenu setAutoenablesItems:NO];
  
  // Show Firefox
  NSMenuItem* showItem = [[NSMenuItem alloc] 
    initWithTitle:@"Show Firefox" 
           action:@selector(showMainWindow:) 
    keyEquivalent:@""];
  [showItem setTarget:mTarget];
  [mMenu addItem:showItem];
  [showItem release];
  
  // Hide Firefox
  NSMenuItem* hideItem = [[NSMenuItem alloc] 
    initWithTitle:@"Hide Firefox" 
           action:@selector(hideToStatusBar:) 
    keyEquivalent:@""];
  [hideItem setTarget:mTarget];
  [mMenu addItem:hideItem];
  [hideItem release];

  // Separator
  [mMenu addItem:[NSMenuItem separatorItem]];

  // Password controls
  NSMenuItem* setPasswordItem =
      [[NSMenuItem alloc] initWithTitle:@"Set Password…"
                                 action:@selector(setPassword:)
                          keyEquivalent:@""];
  [setPasswordItem setTarget:mTarget];
  [mMenu addItem:setPasswordItem];
  mSetPasswordItem = [setPasswordItem retain];
  [setPasswordItem release];

  NSMenuItem* clearPasswordItem =
      [[NSMenuItem alloc] initWithTitle:@"Clear Password"
                                 action:@selector(clearPassword:)
                          keyEquivalent:@""];
  [clearPasswordItem setTarget:mTarget];
  [mMenu addItem:clearPasswordItem];
  mClearPasswordItem = [clearPasswordItem retain];
  [clearPasswordItem release];
  
  // Separator
  [mMenu addItem:[NSMenuItem separatorItem]];
  
  // About Firefox
  NSMenuItem* aboutItem = [[NSMenuItem alloc] 
    initWithTitle:@"About Firefox" 
           action:@selector(menuItemClicked:) 
    keyEquivalent:@""];
  [aboutItem setTarget:mTarget];
  [aboutItem setTag:1001]; // Custom tag for identification
  [mMenu addItem:aboutItem];
  [aboutItem release];
  
  // Separator
  [mMenu addItem:[NSMenuItem separatorItem]];
  
  // Quit Firefox
  NSMenuItem* quitItem = [[NSMenuItem alloc] 
    initWithTitle:@"Quit Firefox" 
           action:@selector(quitApplication:) 
    keyEquivalent:@"q"];
  [quitItem setTarget:mTarget];
  [mMenu addItem:quitItem];
  [quitItem release];

  UpdatePasswordMenuItems();
  
  return true;
  
  NS_OBJC_END_TRY_BLOCK_RETURN(false);
}

void nsStatusBarMenu::SetTitle(const char* aTitle) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  if (!mStatusItem) {
    return;
  }
  
  NSString* title = [NSString stringWithUTF8String:aTitle];
  [mStatusItem setTitle:title];
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsStatusBarMenu::SetIcon(NSImage* aIcon) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  if (!mStatusItem) {
    return;
  }
  
  if (aIcon) {
    [mStatusItem setImage:aIcon];
  }
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsStatusBarMenu::UpdatePasswordMenuItems() {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  BOOL hasPassword = PasswordIsConfigured();
  if (mSetPasswordItem) {
    NSString* title = hasPassword ? @"Change Password…" : @"Set Password…";
    [mSetPasswordItem setTitle:title];
  }
  if (mClearPasswordItem) {
    [mClearPasswordItem setEnabled:hasPassword];
  }

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsStatusBarMenu::Show() {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  if (!mStatusItem) {
    return;
  }
  
  [mStatusItem setLength:NSSquareStatusItemLength];
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsStatusBarMenu::Hide() {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  if (!mStatusItem) {
    return;
  }
  
  [mStatusItem setLength:0];
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsStatusBarMenu::MenuItemClicked(NSMenuItem* aItem) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  NSInteger tag = [aItem tag];
  
  switch (tag) {
    case 1001: { // About Firefox - braces needed for variable declaration
      NSRunningApplication* currentApp = [NSRunningApplication currentApplication];
      [currentApp activateWithOptions:NSApplicationActivateAllWindows |
                                     NSApplicationActivateIgnoringOtherApps];
      break;
    }
    default:
      break;
  }
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}