/* Any copyright is dedicated to the Public Domain.
   http://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

const PASSWORD = "correct horse battery staple";

const { ProtectionPasswordService } = ChromeUtils.importESModule(
  "resource:///modules/ProtectionPasswordService.sys.mjs"
);

add_task(
  async function test_protection_password_lock_ui_shows_password_field() {
    ProtectionPasswordService.init();

    await SpecialPowers.pushPrefEnv({
      set: [
        ["browser.protectionPassword.enabled", true],
        ["browser.protectionPassword.lockOnStartup", false],
        ["browser.protectionPassword.pbkdf2Iterations", 1000],
        ["browser.protectionPassword.salt", ""],
        ["browser.protectionPassword.verifier", ""],
        ["browser.protectionPassword.failureCount", 0],
        ["browser.protectionPassword.lockoutUntil", 0],
      ],
    });

    registerCleanupFunction(async () => {
      try {
        Services.prefs.setIntPref("browser.protectionPassword.lockoutUntil", 0);
        Services.prefs.setIntPref("browser.protectionPassword.failureCount", 0);
        await ProtectionPasswordService.disable(PASSWORD);
      } catch (e) {
        // Best-effort.
      }
    });

    await ProtectionPasswordService.setPassword(PASSWORD);

    let dialogLoaded = TestUtils.topicObserved(
      "subdialog-loaded",
      subject =>
        subject?.location?.href?.includes(
          "chrome://browser/content/protectionPasswordLock.html"
        )
    );
    ProtectionPasswordService.lock();

    await TestUtils.waitForCondition(
      () => window.ProtectionPasswordUI?._lockShown,
      "Waiting for ProtectionPasswordUI to show lock"
    );

    let [dialogWin] = await dialogLoaded;
    await TestUtils.waitForCondition(
      () =>
        dialogWin.document?.location?.href?.includes(
          "chrome://browser/content/protectionPasswordLock.html"
        ),
      "Waiting for lock dialog document"
    );

    info("Lock dialog href: " + dialogWin.location?.href);
    info("Lock dialog docURI: " + dialogWin.document?.documentURI);
    info("Lock dialog root: " + dialogWin.document?.documentElement?.localName);
    info("Lock dialog title: " + dialogWin.document?.title);
    info(
      "Lock dialog outerHTML prefix: " +
        dialogWin.document?.documentElement?.outerHTML?.slice(0, 200)
    );
    info(
      "Lock dialog body prefix: " + dialogWin.document?.body?.innerHTML?.slice(0, 200)
    );

    await TestUtils.waitForCondition(
      () => dialogWin.document?.getElementById("password"),
      "Waiting for password input"
    );
    await TestUtils.waitForCondition(
      () => dialogWin.document?.getElementById("panel"),
      "Waiting for lock panel"
    );

    let doc = dialogWin.document;

    let password = doc.getElementById("password");
    ok(password, "Password input exists");

    let panel = doc.getElementById("panel");
    ok(panel, "Panel exists");

    let panelRect = panel.getBoundingClientRect();
    Assert.greater(panelRect.height, 80, "Panel should not be collapsed");

    let inputRect = password.getBoundingClientRect();
    Assert.greater(inputRect.height, 10, "Password input should be visible");

    let res = await ProtectionPasswordService.unlockWithPassword(PASSWORD);
    ok(res.ok, "Unlock succeeds");

    await TestUtils.waitForCondition(
      () => !window.ProtectionPasswordUI?._lockShown,
      "Waiting for ProtectionPasswordUI to hide lock"
    );
  }
);
