/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

const lazy = {};

ChromeUtils.defineESModuleGetters(lazy, {
  ProtectionPasswordService:
    "resource:///modules/ProtectionPasswordService.sys.mjs",
});

let currentPassword = document.getElementById("currentPassword");
let newPassword = document.getElementById("newPassword");
let confirmPassword = document.getElementById("confirmPassword");
let status = document.getElementById("status");

function setStatus(text) {
  status.textContent = text || "";
}

document.addEventListener("dialogaccept", async event => {
  event.preventDefault();

  if (!currentPassword.value) {
    setStatus("Current password is required.");
    currentPassword.focus();
    return;
  }

  if (!newPassword.value) {
    setStatus("New password is required.");
    newPassword.focus();
    return;
  }

  if (newPassword.value !== confirmPassword.value) {
    setStatus("Passwords do not match.");
    confirmPassword.focus();
    confirmPassword.select();
    return;
  }

  let res;
  try {
    res = await lazy.ProtectionPasswordService.changePassword(
      currentPassword.value,
      newPassword.value
    );
  } catch (e) {
    res = { ok: false, reason: "error" };
  }

  if (!res.ok) {
    if (res.reason === "lockout" || res.reason === "delay") {
      setStatus("Too many attempts. Please try again later.");
    } else {
      setStatus("Wrong password.");
    }
    currentPassword.focus();
    currentPassword.select();
    return;
  }

  window.close();
});

currentPassword.focus();
