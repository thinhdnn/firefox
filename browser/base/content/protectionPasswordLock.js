/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

const lazy = {};

ChromeUtils.defineESModuleGetters(lazy, {
  ProtectionPasswordService:
    "resource:///modules/ProtectionPasswordService.sys.mjs",
});

let passwordInput = document.getElementById("password");
let statusEl = document.getElementById("status");
let form = document.getElementById("form");
let panel = document.getElementById("panel");

function setStatus(text, kind = "error") {
  statusEl.textContent = text || "";
  statusEl.dataset.kind = kind;
}

function focusPassword() {
  passwordInput.focus();
  passwordInput.select();
}

async function formatRetryAfter(ms) {
  let seconds = Math.ceil(ms / 1000);
  return document.l10n.formatValue("protection-password-lock-try-again", {
    seconds,
  });
}

function trapFocus(event) {
  if (event.key !== "Tab") {
    return;
  }

  let focusable = [passwordInput];
  let currentIndex = focusable.indexOf(document.activeElement);
  if (currentIndex === -1) {
    focusable[0].focus();
    event.preventDefault();
    return;
  }

  if (event.shiftKey) {
    currentIndex = (currentIndex - 1 + focusable.length) % focusable.length;
  } else {
    currentIndex = (currentIndex + 1) % focusable.length;
  }

  focusable[currentIndex].focus();
  event.preventDefault();
}

window.addEventListener("message", event => {
  if (event?.data?.type === "protection-password-focus") {
    focusPassword();
  }
});

window.addEventListener(
  "keydown",
  event => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      focusPassword();
      return;
    }

    trapFocus(event);
  },
  { capture: true }
);

window.addEventListener(
  "mousedown",
  () => {
    focusPassword();
  },
  { capture: true }
);

form.addEventListener("submit", async event => {
  event.preventDefault();

  let password = passwordInput.value;
  if (!password) {
    setStatus(
      await document.l10n.formatValue("protection-password-lock-enter-password")
    );
    focusPassword();
    return;
  }

  passwordInput.disabled = true;

  let res;
  try {
    res = await lazy.ProtectionPasswordService.unlockWithPassword(password);
  } catch (e) {
    res = { ok: false, reason: "error" };
  }

  if (res.ok) {
    setStatus("");
    // Close the subdialog immediately so the window becomes interactive again.
    // (The service will also notify other windows to close their lock UI.)
    window.setTimeout(() => {
      try {
        window.close();
      } catch (e) {}
    }, 0);
    return;
  }

  passwordInput.disabled = false;
  passwordInput.value = "";

  if (res.reason === "lockout" || res.reason === "delay") {
    setStatus(await formatRetryAfter(res.retryAfterMs || 0), "info");
  } else {
    setStatus(
      await document.l10n.formatValue("protection-password-lock-wrong-password")
    );
  }

  focusPassword();
});

focusPassword();

(async () => {
  try {
    setStatus(
      await document.l10n.formatValue(
        "protection-password-lock-enter-password"
      ),
      "info"
    );
  } catch (e) {
    setStatus("", "info");
  }
})();
