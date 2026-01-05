/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

const lazyProtectionPassword = {};

ChromeUtils.defineESModuleGetters(lazyProtectionPassword, {
  ProtectionPasswordService:
    "resource:///modules/ProtectionPasswordService.sys.mjs",
});

var ProtectionPasswordUI = {
  _subDialog: null,
  _lockShown: false,
  _blocker: null,
  _cancelListener: null,
  _initializedWindowReady: false,
  _activityListener: null,
  _blockedEventTypes: [
    "keydown",
    "keypress",
    "keyup",
    "mousedown",
    "mouseup",
    "click",
    "dblclick",
    "contextmenu",
    "wheel",
    "dragstart",
    "drop",
  ],

  init() {
    Services.obs.addObserver(this, "protection-password:locked");
    Services.obs.addObserver(this, "protection-password:unlocked");
    Services.obs.addObserver(this, "protection-password:focus");

    Services.obs.addObserver(this, "browser-delayed-startup-finished");

    this._installActivityListener();
  },

  observe(subject, topic) {
    switch (topic) {
      case "protection-password:locked":
        this.showLock();
        break;
      case "protection-password:unlocked":
        this.hideLock();
        break;
      case "protection-password:focus":
        this.focusPasswordField();
        break;
      case "browser-delayed-startup-finished":
        if (subject === window) {
          Services.obs.removeObserver(this, "browser-delayed-startup-finished");
          this._initializedWindowReady = true;
          if (lazyProtectionPassword.ProtectionPasswordService.isLocked) {
            this.showLock();
          }
        }
        break;
    }
  },

  async showLock() {
    if (this._lockShown || window.closed) {
      this.focusPasswordField();
      return;
    }

    if (!this._initializedWindowReady) {
      return;
    }

    let parentElement = document.getElementById("window-modal-dialog");
    let templateHost = document.getElementById("window-modal-dialog-template");
    if (!parentElement || !templateHost || !window.gBrowser) {
      return;
    }

    this._lockShown = true;

    try {
      window.focus();
    } catch (e) {
      // Best-effort.
    }

    this._installTopLevelInputBlocker();

    try {
      gURLBar.incrementBreakoutBlockerCount();
    } catch (e) {
      // Best-effort.
    }

    try {
      parentElement.setAttribute("protection-password", "true");
      this._cancelListener = event => {
        event.preventDefault();
      };
      parentElement.addEventListener("cancel", this._cancelListener, {
        capture: true,
      });

      let offset = 0;
      try {
        let selected = gBrowser?.selectedBrowser;
        if (selected) {
          offset = window.windowUtils.getBoundsWithoutFlushing(selected).top;
        }
      } catch (e) {
        // Best-effort; fall back to 0.
      }

      parentElement.style.setProperty("--chrome-offset", offset + "px");
      parentElement.style.removeProperty("visibility");
      parentElement.style.removeProperty("width");
      parentElement.style.removeProperty("height");
      document.documentElement.setAttribute("window-modal-open", true);

      if (!parentElement.open) {
        parentElement.showModal();
      }

      try {
        gDialogBox._updateMenuAndCommandState(false);
      } catch (e) {
        // Best-effort.
      }

      try {
        UpdatePopupNotificationsVisibility();
      } catch (e) {
        // Best-effort.
      }

      let template = templateHost.content.firstElementChild;

      this._subDialog = new SubDialog({
        template,
        parentElement,
        id: "window-modal-dialog-protection-password",
        options: {
          consumeOutsideClicks: false,
        },
        dialogOptions: {
          consumeOutsideClicks: false,
        },
      });

      this._subDialog.open(
        "chrome://browser/content/protectionPasswordLock.html",
        {
          features: "resizable=no",
          modalType: Ci.nsIPrompt.MODAL_TYPE_INTERNAL_WINDOW,
          closedCallback: () => {},
        },
        null
      );
    } catch (e) {
      this._lockShown = false;
      this._removeTopLevelInputBlocker();
      this._subDialog = null;

      try {
        if (parentElement.open) {
          parentElement.close();
        }
      } catch (err) {
        // Best-effort cleanup.
      }

      try {
        parentElement.removeAttribute("protection-password");
      } catch (err) {
        // Best-effort cleanup.
      }

      try {
        document.documentElement.removeAttribute("window-modal-open");
      } catch (err) {
        // Best-effort cleanup.
      }

      try {
        gDialogBox._updateMenuAndCommandState(true);
      } catch (err) {
        // Best-effort cleanup.
      }

      try {
        UpdatePopupNotificationsVisibility();
      } catch (err) {
        // Best-effort cleanup.
      }

      return;
    }

    this.focusPasswordField();
  },

  hideLock() {
    if (!this._lockShown) {
      return;
    }

    this._lockShown = false;

    this._removeTopLevelInputBlocker();

    let parentElement = document.getElementById("window-modal-dialog");

    if (parentElement && this._cancelListener) {
      try {
        parentElement.removeEventListener("cancel", this._cancelListener, {
          capture: true,
        });
      } catch (e) {
        // Best-effort.
      }
      this._cancelListener = null;
    }

    try {
      this._subDialog?.close();
    } catch (e) {
      // Best-effort.
    }

    if (parentElement?.open) {
      parentElement.close();
    }

    if (parentElement) {
      parentElement.removeAttribute("protection-password");
      parentElement.style.visibility = "hidden";
      parentElement.style.height = "0";
      parentElement.style.width = "0";
    }
    document.documentElement.removeAttribute("window-modal-open");

    gDialogBox._updateMenuAndCommandState(true);

    UpdatePopupNotificationsVisibility();

    try {
      gURLBar.decrementBreakoutBlockerCount();
    } catch (e) {
      // Best-effort.
    }

    this._subDialog = null;
  },

  focusPasswordField() {
    if (!this._lockShown) {
      return;
    }
    try {
      this._subDialog?.frameContentWindow?.postMessage(
        { type: "protection-password-focus" },
        "*"
      );
    } catch (e) {
      // Best-effort.
    }
  },

  _installTopLevelInputBlocker() {
    if (this._blocker) {
      return;
    }

    this._blocker = event => {
      if (!this._lockShown) {
        return;
      }

      let frameWin = this._subDialog?.frameContentWindow;
      if (frameWin) {
        if (event.view === frameWin) {
          return;
        }

        let target = event.target;
        if (target?.ownerGlobal === frameWin) {
          return;
        }

        let originalTarget = event.originalTarget || event.explicitOriginalTarget;
        if (originalTarget?.ownerGlobal === frameWin) {
          return;
        }
      }

      let dialog = document.getElementById("window-modal-dialog");
      if (dialog) {
        let target = event.target;
        if (target && dialog.contains(target)) {
          return;
        }

        // Some events can be retargeted in chrome; also allow input when focus
        // is currently inside the dialog.
        let originalTarget = event.originalTarget || event.explicitOriginalTarget;
        if (originalTarget && dialog.contains(originalTarget)) {
          return;
        }

        let active = document.activeElement;
        if (active && dialog.contains(active)) {
          return;
        }
      }

      event.preventDefault();
      event.stopPropagation();
    };

    for (let type of this._blockedEventTypes) {
      window.addEventListener(type, this._blocker, true);
    }
  },

  _removeTopLevelInputBlocker() {
    if (!this._blocker) {
      return;
    }

    for (let type of this._blockedEventTypes) {
      window.removeEventListener(type, this._blocker, true);
    }
    this._blocker = null;
  },

  _installActivityListener() {
    if (this._activityListener) {
      return;
    }

    let lastNote = 0;
    this._activityListener = () => {
      if (this._lockShown) {
        return;
      }
      if (lazyProtectionPassword.ProtectionPasswordService.isLocked) {
        return;
      }
      let now = Date.now();
      if (now - lastNote < 1000) {
        return;
      }
      lastNote = now;
      lazyProtectionPassword.ProtectionPasswordService.noteUserActivity();
    };

    for (let type of ["keydown", "mousedown", "wheel", "touchstart"]) {
      window.addEventListener(type, this._activityListener, { capture: true });
    }
  },
};

ProtectionPasswordUI.init();
