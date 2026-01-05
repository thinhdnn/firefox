/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

const lazy = {};

ChromeUtils.defineESModuleGetters(lazy, {
  ProtectionPasswordService:
    "resource:///modules/ProtectionPasswordService.sys.mjs",
});

let newPassword = document.getElementById("newPassword");
let confirmPassword = document.getElementById("confirmPassword");
let status = document.getElementById("status");

function setStatus(text) {
  status.textContent = text || "";
}

function focusFirst() {
  newPassword.focus();
}

document.addEventListener("dialogaccept", async event => {
  event.preventDefault();

  if (!newPassword.value) {
    setStatus("Password is required.");
    focusFirst();
    return;
  }

  if (newPassword.value !== confirmPassword.value) {
    setStatus("Passwords do not match.");
    confirmPassword.focus();
    confirmPassword.select();
    return;
  }

  try {
    await lazy.ProtectionPasswordService.setPassword(newPassword.value);
  } catch (e) {
    setStatus("Failed to set password.");
    return;
  }

  window.close();
});

focusFirst();
