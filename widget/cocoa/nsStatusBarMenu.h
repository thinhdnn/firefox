/* -*- Mode: c++; tab-width: 2; indent-tabs-mode: nil; -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef nsStatusBarMenu_h_
#define nsStatusBarMenu_h_

#import <Cocoa/Cocoa.h>

@class NSStatusItem;
@class MOZStatusBarTarget;

class nsStatusBarMenu {
 public:
  nsStatusBarMenu();
  virtual ~nsStatusBarMenu();

  bool Init();
  void SetTitle(const char* aTitle);
  void SetIcon(NSImage* aIcon);
  void Show();
  void Hide();
  
  void MenuItemClicked(NSMenuItem* aItem);

 private:
  NSStatusItem* mStatusItem;
  NSMenu* mMenu;
  MOZStatusBarTarget* mTarget;
  
  bool BuildStatusMenu();
};

@interface MOZStatusBarTarget : NSObject {
  nsStatusBarMenu* mStatusBarMenu;
}

- (id)initWithStatusBarMenu:(nsStatusBarMenu*)aStatusBarMenu;
- (void)menuItemClicked:(id)sender;
- (void)showMainWindow:(id)sender;
- (void)hideToStatusBar:(id)sender;
- (void)quitApplication:(id)sender;

@end

#endif // nsStatusBarMenu_h_