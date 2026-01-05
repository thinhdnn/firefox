/* Any copyright is dedicated to the Public Domain.
   http://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

const PASSWORD = "correct horse battery staple";
const WIDGET_ID = "protection-password-lock-button";

const { ProtectionPasswordService } = ChromeUtils.importESModule(
  "resource:///modules/ProtectionPasswordService.sys.mjs"
);

function observeOnce(topic) {
  return new Promise(resolve => {
    Services.obs.addObserver(function obs(subject, _topic, data) {
      Services.obs.removeObserver(obs, topic);
      resolve({ subject, data });
    }, topic);
  });
}

async function ensureWidgetNode(win) {
  let placement = CustomizableUI.getPlacementOfWidget(WIDGET_ID);
  if (!placement) {
    CustomizableUI.addWidgetToArea(WIDGET_ID, CustomizableUI.AREA_NAVBAR);
  }

  await TestUtils.waitForCondition(() => {
    let widget = CustomizableUI.getWidget(WIDGET_ID);
    return !!widget?.forWindow(win)?.node;
  }, "Waiting for protection password widget node");

  return CustomizableUI.getWidget(WIDGET_ID).forWindow(win).node;
}

add_task(async function test_protection_password_lock_unlock_lockout_toolbar() {
  ProtectionPasswordService.init();

  await SpecialPowers.pushPrefEnv({
    set: [
      ["browser.protectionPassword.enabled", true],
      ["browser.protectionPassword.lockOnStartup", false],
      ["browser.protectionPassword.idleLockTimeoutSeconds", 0],
      ["browser.protectionPassword.pbkdf2Iterations", 1000],
      ["browser.protectionPassword.salt", ""],
      ["browser.protectionPassword.verifier", ""],
      ["browser.protectionPassword.failureCount", 0],
      ["browser.protectionPassword.lockoutUntil", 0],
    ],
  });

  let initialPlacement = CustomizableUI.getPlacementOfWidget(WIDGET_ID);

  registerCleanupFunction(async () => {
    try {
      Services.prefs.setIntPref("browser.protectionPassword.lockoutUntil", 0);
      Services.prefs.setIntPref("browser.protectionPassword.failureCount", 0);
      await ProtectionPasswordService.disable(PASSWORD);
    } catch (e) {}

    try {
      if (!initialPlacement) {
        CustomizableUI.removeWidgetFromArea(WIDGET_ID);
      }
    } catch (e) {}
  });

  await ProtectionPasswordService.setPassword(PASSWORD);

  ok(!ProtectionPasswordService.isLocked, "Starts unlocked");

  let node = await ensureWidgetNode(window);

  await TestUtils.waitForCondition(() => {
    return (
      node.getAttribute("data-l10n-id") === "protection-password-toolbar-button"
    );
  }, "Widget should have unlocked l10n id");

  ProtectionPasswordService.lock();

  await TestUtils.waitForCondition(
    () => ProtectionPasswordService.isLocked,
    "Service should be locked"
  );

  await TestUtils.waitForCondition(() => {
    return (
      node.getAttribute("data-l10n-id") ===
      "protection-password-toolbar-button-locked"
    );
  }, "Widget should have locked l10n id");

  let focusPromise = observeOnce("protection-password:focus");
  ProtectionPasswordService.lock();
  await focusPromise;
  ok(true, "Locking while locked requests focus");

  for (let i = 0; i < 2; i++) {
    let res = await ProtectionPasswordService.unlockWithPassword("wrong");
    Assert.deepEqual(
      { ok: res.ok, reason: res.reason },
      { ok: false, reason: "wrong" },
      "Wrong password is rejected"
    );
  }

  let delayed = await ProtectionPasswordService.unlockWithPassword("wrong");
  ok(!delayed.ok, "Still locked after wrong password");
  is(delayed.reason, "delay", "Third failure triggers a delay");
  Assert.greaterOrEqual(
    delayed.retryAfterMs,
    5000,
    "Delay includes retryAfterMs"
  );

  let lockedOut = await ProtectionPasswordService.unlockWithPassword(PASSWORD);
  ok(!lockedOut.ok, "Correct password is blocked during lockout");
  is(lockedOut.reason, "lockout", "Lockout is enforced");
  ok(ProtectionPasswordService.isLocked, "Still locked during lockout");

  Services.prefs.setIntPref("browser.protectionPassword.lockoutUntil", 0);
  Services.prefs.setIntPref("browser.protectionPassword.failureCount", 0);

  let unlocked = await ProtectionPasswordService.unlockWithPassword(PASSWORD);
  ok(unlocked.ok, "Correct password unlocks when not locked out");
  ok(!ProtectionPasswordService.isLocked, "Now unlocked");

  await TestUtils.waitForCondition(() => {
    return (
      node.getAttribute("data-l10n-id") === "protection-password-toolbar-button"
    );
  }, "Widget should return to unlocked l10n id");

  Services.prefs.setIntPref("browser.protectionPassword.idleLockTimeoutSeconds", 1);
  ProtectionPasswordService.noteUserActivity();

  await new Promise(resolve => setTimeout(resolve, 2500));
  await TestUtils.waitForCondition(
    () => ProtectionPasswordService.isLocked,
    "Service should auto-lock after inactivity"
  );
});
