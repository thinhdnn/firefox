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

namespace {

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
  nsCOMPtr<nsINativeAppSupport> nativeSupport = NS_GetNativeAppSupport();
  if (nativeSupport) {
    nativeSupport->ReOpen();
    return true;
  }

  return RestoreViaWindowMediator();
}

}  // namespace

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
  
  printf("🦊 Show Firefox clicked\n");
  
  // First, try sending a notification to show windows
  [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowFirefoxWindows" object:nil];
  
  // Activate without switching to a Dock-visible activation policy
  NSRunningApplication* currentApp = [NSRunningApplication currentApplication];
  [currentApp activateWithOptions:NSApplicationActivateAllWindows |
                                 NSApplicationActivateIgnoringOtherApps];

  bool restoredByGecko = RestoreFirefoxWindows();
  if (restoredByGecko) {
    printf("🦊 Restored windows via Gecko window mediator\n");
  } else {
    // Small delay to let activation complete
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      // Now show windows
      BOOL foundMainWindow = NO;
      
      for (NSWindow* window in [NSApp windows]) {
        // Look for browser windows (exclude panels, menus, etc)
        if (window.contentView != nil && 
            ![window.className containsString:@"Panel"] &&
            ![window.className containsString:@"Menu"] &&
            ![window.className containsString:@"Popup"] &&
            window.frame.size.width > 300 && 
            window.frame.size.height > 200) {
          
          printf("🦊 Found browser window: %s\n", [window.className UTF8String]);
          
          // Try multiple ways to show the window
          [window setIsVisible:YES];
          [window makeKeyAndOrderFront:nil];
          [window orderFrontRegardless];
          [window deminiaturize:nil]; // In case it's minimized
          
          foundMainWindow = YES;
        }
      }
      
      if (!foundMainWindow) {
        printf("🦊 No suitable window found, showing all windows\n");
        for (NSWindow* window in [NSApp windows]) {
          if (window.contentView != nil) {
            printf("🦊 Showing window: %s\n", [window.className UTF8String]);
            [window setIsVisible:YES];
            [window makeKeyAndOrderFront:nil];
            [window deminiaturize:nil];
          }
        }
      }

    });
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
  
  // Hide all windows
  for (NSWindow* window in [NSApp windows]) {
    if ([window isVisible] && window.contentView != nil) {
      [window orderOut:nil];
    }
  }
  
  // Change activation policy back to accessory
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  printf("🦊 Set activation policy back to Accessory\n");
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

@end

// nsStatusBarMenu implementation
nsStatusBarMenu::nsStatusBarMenu()
    : mStatusItem(nullptr),
      mMenu(nullptr),
      mTarget(nullptr) {
}

nsStatusBarMenu::~nsStatusBarMenu() {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  
  if (mStatusItem) {
    [[NSStatusBar systemStatusBar] removeStatusItem:mStatusItem];
    [mStatusItem release];
  }
  
  if (mMenu) {
    [mMenu release];
  }
  
  if (mTarget) {
    [mTarget release];
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
    case 1001: // About Firefox
      // Could open about dialog here
      // For now, just activate the app
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      [NSApp activateIgnoringOtherApps:YES];
      break;
    default:
      break;
  }
  
  NS_OBJC_END_TRY_IGNORE_BLOCK;
}