/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

import { CommonUtils } from "resource://services-common/utils.sys.mjs";
import { CryptoUtils } from "moz-src:///services/crypto/modules/utils.sys.mjs";

const lazy = {};

ChromeUtils.defineESModuleGetters(lazy, {
  CustomizableUI:
    "moz-src:///browser/components/customizableui/CustomizableUI.sys.mjs",
  clearTimeout: "resource://gre/modules/Timer.sys.mjs",
  setTimeout: "resource://gre/modules/Timer.sys.mjs",
});

const PREF_BRANCH = "browser.protectionPassword.";

const PREF_ENABLED = PREF_BRANCH + "enabled";
const PREF_LOCK_ON_STARTUP = PREF_BRANCH + "lockOnStartup";
const PREF_IDLE_LOCK_TIMEOUT_SECONDS = PREF_BRANCH + "idleLockTimeoutSeconds";
const PREF_SALT = PREF_BRANCH + "salt";
const PREF_VERIFIER = PREF_BRANCH + "verifier";
const PREF_PBKDF2_ITERS = PREF_BRANCH + "pbkdf2Iterations";

const PREF_FAILURE_COUNT = PREF_BRANCH + "failureCount";
const PREF_LOCKOUT_UNTIL = PREF_BRANCH + "lockoutUntil";

const TOPIC_LOCKED = "protection-password:locked";
const TOPIC_UNLOCKED = "protection-password:unlocked";
const TOPIC_FOCUS = "protection-password:focus";

const WIDGET_ID = "protection-password-lock-button";
const WIDGET_PLACED_PREF = PREF_BRANCH + "widgetAdded";

const SALT_BYTES = 16;
const VERIFIER_BYTES = 32;

function nowSec() {
  return Math.floor(Date.now() / 1000);
}

function encodeBytes(bytes) {
  return ChromeUtils.base64URLEncode(asUint8Array(bytes), { pad: false });
}

function decodeBytes(str) {
  if (!str) {
    return null;
  }
  return asUint8Array(ChromeUtils.base64URLDecode(str, { padding: "ignore" }));
}

function asUint8Array(value) {
  if (!value) {
    return null;
  }
  if (value instanceof Uint8Array) {
    return value;
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new TypeError("Unsupported byte buffer type");
}

function byteStringToBytes(byteString) {
  return new Uint8Array(CommonUtils.byteStringToArrayBuffer(byteString));
}

function bytesToByteString(bytes) {
  return CommonUtils.arrayBufferToByteString(asUint8Array(bytes));
}

function timingSafeEqualBytes(a, b) {
  if (!a || !b || a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff === 0;
}

function computeLockoutDelayMs(failureCount) {
  if (failureCount <= 2) {
    return 0;
  }
  if (failureCount === 3) {
    return 5_000;
  }
  if (failureCount === 4) {
    return 15_000;
  }
  if (failureCount === 5) {
    return 30_000;
  }
  return 60_000;
}

async function deriveVerifierBytes(password, saltBytes, iterations) {
  let passwordOctets = CommonUtils.encodeUTF8(password);
  let saltOctets = bytesToByteString(saltBytes);
  let derivedOctets = await CryptoUtils.pbkdf2Generate(
    passwordOctets,
    saltOctets,
    iterations,
    VERIFIER_BYTES
  );
  return byteStringToBytes(derivedOctets);
}

export const ProtectionPasswordService = new (class {
  #initialized = false;
  #widgetCreated = false;
  #locked = false;
  #idleTimer = null;
  #idleTimerGeneration = 0;
  #lastActivityMs = 0;

  maybeEarlyInit() {
    if (this.#initialized) {
      return;
    }
    this.#initialized = true;

    Services.prefs.addObserver(PREF_ENABLED, this);
    Services.prefs.addObserver(PREF_IDLE_LOCK_TIMEOUT_SECONDS, this);

    if (this.enabled && this.lockOnStartup) {
      this.#locked = true;
      Services.obs.notifyObservers(null, TOPIC_LOCKED);
    }

    this.#lastActivityMs = Date.now();
    this.#updateIdleTimer();
  }

  init() {
    this.maybeEarlyInit();

    if (!this.#widgetCreated) {
      this.#createWidget();
      this.#widgetCreated = true;
    }

    this.#updateIdleTimer();
  }

  observe(_subject, topic, data) {
    if (topic !== "nsPref:changed") {
      return;
    }
    if (data !== PREF_ENABLED && data !== PREF_IDLE_LOCK_TIMEOUT_SECONDS) {
      return;
    }
    this.#lastActivityMs = Date.now();
    this.#updateIdleTimer();
  }

  get enabled() {
    return Services.prefs.getBoolPref(PREF_ENABLED, false);
  }

  set enabled(value) {
    Services.prefs.setBoolPref(PREF_ENABLED, !!value);
  }

  get lockOnStartup() {
    return Services.prefs.getBoolPref(PREF_LOCK_ON_STARTUP, true);
  }

  set lockOnStartup(value) {
    Services.prefs.setBoolPref(PREF_LOCK_ON_STARTUP, !!value);
  }

  get idleLockTimeoutSeconds() {
    return Services.prefs.getIntPref(PREF_IDLE_LOCK_TIMEOUT_SECONDS, 0);
  }

  set idleLockTimeoutSeconds(value) {
    Services.prefs.setIntPref(PREF_IDLE_LOCK_TIMEOUT_SECONDS, Math.max(0, value | 0));
  }

  get isPasswordSet() {
    return !!Services.prefs.getStringPref(PREF_VERIFIER, "");
  }

  get isLocked() {
    return this.#locked;
  }

  noteUserActivity() {
    this.maybeEarlyInit();
    if (!this.enabled || !this.isPasswordSet || this.#locked) {
      return;
    }
    this.#lastActivityMs = Date.now();
    this.#updateIdleTimer();
  }

  lock() {
    this.maybeEarlyInit();
    if (!this.enabled || !this.isPasswordSet) {
      return;
    }
    if (this.#locked) {
      Services.obs.notifyObservers(null, TOPIC_FOCUS);
      return;
    }
    this.#locked = true;
    this.#clearIdleTimer();
    Services.obs.notifyObservers(null, TOPIC_LOCKED);
    this.#updateWidgetWindows();
  }

  requestFocus() {
    if (!this.#locked) {
      return;
    }
    Services.obs.notifyObservers(null, TOPIC_FOCUS);
  }

  async unlockWithPassword(password) {
    this.maybeEarlyInit();
    if (!this.#locked) {
      return { ok: true };
    }

    let lockoutUntil = Services.prefs.getIntPref(PREF_LOCKOUT_UNTIL, 0);
    let now = nowSec();
    if (lockoutUntil > now) {
      return {
        ok: false,
        reason: "lockout",
        retryAfterMs: (lockoutUntil - now) * 1000,
      };
    }

    let salt = decodeBytes(Services.prefs.getStringPref(PREF_SALT, ""));
    let verifier = decodeBytes(Services.prefs.getStringPref(PREF_VERIFIER, ""));
    let iterations = Services.prefs.getIntPref(PREF_PBKDF2_ITERS, 200_000);

    if (!salt || !verifier) {
      return { ok: false, reason: "not-configured" };
    }

    let derived = await deriveVerifierBytes(password, salt, iterations);

    if (!timingSafeEqualBytes(derived, verifier)) {
      let failureCount = Services.prefs.getIntPref(PREF_FAILURE_COUNT, 0) + 1;
      Services.prefs.setIntPref(PREF_FAILURE_COUNT, failureCount);

      let delay = computeLockoutDelayMs(failureCount);
      let until = delay ? now + Math.ceil(delay / 1000) : 0;
      Services.prefs.setIntPref(PREF_LOCKOUT_UNTIL, until);

      return {
        ok: false,
        reason: delay ? "delay" : "wrong",
        retryAfterMs: delay,
      };
    }

    Services.prefs.setIntPref(PREF_FAILURE_COUNT, 0);
    Services.prefs.setIntPref(PREF_LOCKOUT_UNTIL, 0);

    this.#locked = false;
    Services.obs.notifyObservers(null, TOPIC_UNLOCKED);
    this.#updateWidgetWindows();

    this.#lastActivityMs = Date.now();
    this.#updateIdleTimer();

    return { ok: true };
  }

  async setPassword(newPassword) {
    this.maybeEarlyInit();

    if (!newPassword) {
      throw new Error("Password must not be empty");
    }

    let saltOctets = CryptoUtils.generateRandomBytesLegacy(SALT_BYTES);
    let salt = byteStringToBytes(saltOctets);

    let iterations = Services.prefs.getIntPref(PREF_PBKDF2_ITERS, 200_000);
    let verifier = await deriveVerifierBytes(newPassword, salt, iterations);

    Services.prefs.setStringPref(PREF_SALT, encodeBytes(salt));
    Services.prefs.setStringPref(PREF_VERIFIER, encodeBytes(verifier));

    Services.prefs.setIntPref(PREF_FAILURE_COUNT, 0);
    Services.prefs.setIntPref(PREF_LOCKOUT_UNTIL, 0);

    this.#lastActivityMs = Date.now();
    this.#updateIdleTimer();
  }

  async changePassword(currentPassword, newPassword) {
    let res = await this.#verifyPassword(currentPassword);
    if (!res.ok) {
      return res;
    }
    await this.setPassword(newPassword);
    return { ok: true };
  }

  async disable(currentPassword) {
    let res = await this.#verifyPassword(currentPassword);
    if (!res.ok) {
      return res;
    }

    this.enabled = false;

    this.#clearIdleTimer();

    Services.prefs.clearUserPref(PREF_SALT);
    Services.prefs.clearUserPref(PREF_VERIFIER);

    Services.prefs.clearUserPref(PREF_FAILURE_COUNT);
    Services.prefs.clearUserPref(PREF_LOCKOUT_UNTIL);

    if (this.#locked) {
      this.#locked = false;
      Services.obs.notifyObservers(null, TOPIC_UNLOCKED);
      this.#updateWidgetWindows();
    }

    return { ok: true };
  }

  #clearIdleTimer() {
    if (!this.#idleTimer) {
      return;
    }
    lazy.clearTimeout(this.#idleTimer);
    this.#idleTimer = null;
    this.#idleTimerGeneration++;
  }

  #updateIdleTimer() {
    this.#clearIdleTimer();

    if (!this.enabled || !this.isPasswordSet || this.#locked) {
      return;
    }

    let timeoutSeconds = this.idleLockTimeoutSeconds;
    if (!timeoutSeconds) {
      return;
    }

    let timeoutMs = timeoutSeconds * 1000;
    let remainingMs = timeoutMs - (Date.now() - this.#lastActivityMs);
    if (remainingMs <= 0) {
      this.lock();
      return;
    }

    let generation = ++this.#idleTimerGeneration;
    this.#idleTimer = lazy.setTimeout(() => {
      if (generation !== this.#idleTimerGeneration) {
        return;
      }
      this.#idleTimer = null;
      this.lock();
    }, remainingMs);
  }

  async #verifyPassword(password) {
    if (!this.isPasswordSet) {
      return { ok: false, reason: "not-configured" };
    }

    let lockoutUntil = Services.prefs.getIntPref(PREF_LOCKOUT_UNTIL, 0);
    let now = nowSec();
    if (lockoutUntil > now) {
      return {
        ok: false,
        reason: "lockout",
        retryAfterMs: (lockoutUntil - now) * 1000,
      };
    }

    let salt = decodeBytes(Services.prefs.getStringPref(PREF_SALT, ""));
    let verifier = decodeBytes(Services.prefs.getStringPref(PREF_VERIFIER, ""));
    let iterations = Services.prefs.getIntPref(PREF_PBKDF2_ITERS, 200_000);

    if (!salt || !verifier) {
      return { ok: false, reason: "not-configured" };
    }

    let derived = await deriveVerifierBytes(password, salt, iterations);

    if (!timingSafeEqualBytes(derived, verifier)) {
      let failureCount = Services.prefs.getIntPref(PREF_FAILURE_COUNT, 0) + 1;
      Services.prefs.setIntPref(PREF_FAILURE_COUNT, failureCount);

      let delay = computeLockoutDelayMs(failureCount);
      let until = delay ? now + Math.ceil(delay / 1000) : 0;
      Services.prefs.setIntPref(PREF_LOCKOUT_UNTIL, until);

      return {
        ok: false,
        reason: delay ? "delay" : "wrong",
        retryAfterMs: delay,
      };
    }

    Services.prefs.setIntPref(PREF_FAILURE_COUNT, 0);
    Services.prefs.setIntPref(PREF_LOCKOUT_UNTIL, 0);

    return { ok: true };
  }

  #createWidget() {
    const item = {
      id: WIDGET_ID,
      type: "button",
      label: "Lock",
      tooltiptext: "Lock",
      onClick: (_event, _node) => {
        if (this.isLocked) {
          this.requestFocus();
        } else {
          this.lock();
        }
      },
      onCreated: node => {
        this.#updateWidgetNode(node);
      },
    };

    lazy.CustomizableUI.createWidget(item);

    let wasAdded = Services.prefs.getBoolPref(WIDGET_PLACED_PREF, false);
    let alreadyPlaced = lazy.CustomizableUI.getPlacementOfWidget(
      WIDGET_ID,
      false,
      true
    );
    if (!wasAdded && !alreadyPlaced) {
      lazy.CustomizableUI.addWidgetToArea(
        WIDGET_ID,
        lazy.CustomizableUI.AREA_NAVBAR,
        null
      );
      Services.prefs.setBoolPref(WIDGET_PLACED_PREF, true);
    }
  }

  #updateWidgetNode(node) {
    node.classList.toggle("protection-password-locked", this.isLocked);
    node.classList.add("toolbarbutton-1");
    node.setAttribute("image", "chrome://global/skin/icons/security.svg");

    let doc = node.ownerDocument;
    doc.l10n.setAttributes(
      node,
      this.isLocked
        ? "protection-password-toolbar-button-locked"
        : "protection-password-toolbar-button"
    );
  }

  #updateWidgetWindows() {
    let widget = lazy.CustomizableUI.getWidget(WIDGET_ID);
    if (!widget) {
      return;
    }
    for (let win of Services.wm.getEnumerator("navigator:browser")) {
      if (win.closed) {
        continue;
      }
      let instance = widget.forWindow(win);
      if (instance?.node) {
        this.#updateWidgetNode(instance.node);
      }
    }
  }
})();
