# ha-android-authproxy

**A thin, auto-built distribution of the [Home Assistant Android companion app](https://github.com/home-assistant/android) with one patch on top: support for connecting through an OIDC/OAuth2 authentication proxy.**

This repository does **not** contain a fork of the Home Assistant app. It contains a single patch, a few helper scripts, and a GitHub Actions workflow that clones upstream at its latest `main` commit, applies the patch, builds a debug APK, and publishes it as a GitHub Release. When upstream advances, a new build is produced automatically.

---

## Table of contents

- [What this is and who it's for](#what-this-is-and-who-its-for)
- [What works, and the federated-login limitation](#what-works-and-the-federated-login-limitation)
- [The problem it solves](#the-problem-it-solves)
- [Exactly what is modified](#exactly-what-is-modified)
- [Trust and security](#trust-and-security)
- [Installing](#installing)
- [Versioning](#versioning)
- [How to get notified of new releases](#how-to-get-notified-of-new-releases)
- [Building it yourself](#building-it-yourself)
- [How the auto-build works](#how-the-auto-build-works)
- [For contributors: updating the patch when upstream breaks it](#for-contributors-updating-the-patch-when-upstream-breaks-it)
- [Why this isn't in Home Assistant core](#why-this-isnt-in-home-assistant-core-and-may-not-ever-be)
- [Disclaimers and attribution](#disclaimers-and-attribution)

---

## What this is and who it's for

The official Home Assistant Android app does not let you put a **forward-auth / identity-aware proxy** in front of your Home Assistant instance. If you do, the app's onboarding and token-refresh flows break: the proxy's login challenge gets ejected to the system browser, the resulting session cookie never makes it back into the app's WebView, and you can't finish connecting.

This project ships the **standard, unmodified Home Assistant app** with **one small patch** that keeps that auth handshake inside the WebView, so the proxy login completes and you reach Home Assistant normally.

It is for self-hosters who:

- Sit Home Assistant behind an OIDC/OAuth2 auth proxy such as **Cloudflare Access, Authelia, Authentik, Vouch, or oauth2-proxy**, and
- Are comfortable **sideloading a debug-signed APK** and reading/verifying the change (or building it themselves).

If you don't run an auth proxy, you don't need this — use the official app from Google Play or [F-Droid](https://f-droid.org/packages/io.homeassistant.companion.android.minimal/).

---

## What works, and the federated-login limitation

**Check this before you install** — one specific setup (Google/Microsoft *federated* sign-in) cannot be made to work by this or any client-side patch, so confirm your login factor is supported here first.

**What works:** connecting through a proxy that challenges you **before** you reach Home Assistant, including:

- **Cloudflare Access**
- **Authelia**
- **Authentik**
- **Vouch**
- **oauth2-proxy**

…using a login factor the proxy can render inside an embedded WebView (see below). Onboarding, normal use, and token refresh all complete in-app.

### The Google / Microsoft federated-login limitation

> **Google and Microsoft federated sign-in will not work in this app — and cannot be fixed by this patch.**

If your proxy delegates the actual login to **"Sign in with Google"** or **"Sign in with Microsoft"**, those providers **refuse to render in any embedded WebView** and return **`Error 403: disallowed_useragent`**. This is a **published, deliberate Google/Microsoft policy** that blocks OAuth flows inside embedded WebViews across all apps. It is not a bug in this patch, and no client-side patch can override it.

**Workarounds** (pick one):

1. **Use a non-federated factor on the proxy** for the app — e.g. **email OTP, TOTP, or WebAuthn / passkeys** instead of Google/Microsoft SSO.
2. **Put a self-hosted identity provider in front** (Authelia, Authentik, Keycloak, etc.) that can render its own login form in a WebView, even if it federates to Google/Microsoft for browser logins.

In short: anything that draws its **own** login UI works; anything that bounces you to Google's or Microsoft's hosted consent screen does not.

---

## The problem it solves

When an OIDC/OAuth2 auth proxy is in front of Home Assistant, the first request from the app is redirected to the proxy's identity provider for a login challenge. The stock app treats that off-origin redirect as a "user clicked an external link" event and hands it to the system browser. Authentication then completes **in Chrome**, the session cookie lands in **Chrome's** cookie jar, and the app's WebView never sees it. Both first-time onboarding and silent token refresh fail.

The fix is to distinguish two kinds of navigation:

- **Auth handshakes** — server-initiated redirects and main-frame navigation away from the anchored Home Assistant host — should **stay inside the WebView**.
- **User-initiated external links** — should keep going to the system browser, exactly as before.

This was proposed upstream as **[home-assistant/android#6725](https://github.com/home-assistant/android/pull/6725)** ("support external authentication providers in front of Home Assistant"). It was **closed, not merged**: the maintainers decided that external-auth-provider support belongs in Home Assistant **core** rather than in each client, and raised security concerns about broadening what the WebView is allowed to load while the JavaScript auth bridge is present.

A separate, self-contained security-hardening change, **[home-assistant/android#6733](https://github.com/home-assistant/android/pull/6733)** ("tie legacy externalApp bridge lifecycle to the configured server origin"), tightened when the token-bearing JavaScript bridge is exposed — removing it when the WebView is off-origin and restoring it on return, so the auth-token bridge is only ever live on your real Home Assistant origin and never on a proxy's login pages. It was offered as a standalone hardening that stands on its own merits regardless of the feature. It was **also closed, not merged**; the maintainer's reasoning was that the hardening is *"only relevant if we ever allow loading an url that is not Home Assistant"* — i.e. it only matters if the feature in #6725 is accepted, which they had already declined. That hardening still informs this patch's design.

So **both** the feature and the defence-in-depth that would accompany it were declined. See [Why this isn't in Home Assistant core](#why-this-isnt-in-home-assistant-core-and-may-not-ever-be) for the architectural, philosophical, and (speculatively) commercial reasons — and why that's unlikely to change.

This repository exists so people who already run an auth proxy can keep using the app **today**, on top of current upstream, until (or unless) Home Assistant core addresses it.

---

## Exactly what is modified

The entire change is one git `format-patch` file:

**[`patches/0001-auth-proxy-redirect-support.patch`](patches/0001-auth-proxy-redirect-support.patch)**

It touches **exactly three Kotlin files** (roughly **61 insertions, 2 deletions**) and adds no new dependencies, permissions, or network endpoints:

| File | Change |
| --- | --- |
| `app/.../util/TLSWebViewClient.kt` | Overrides `shouldOverrideUrlLoading(WebResourceRequest)` so that **main-frame auth-provider navigation** — server redirects, and clicks made while you are still off the anchored Home Assistant host — is kept **inside** the WebView instead of being handed to the system browser. |
| `app/.../webview/WebViewActivity.kt` | Holds onto the `TLSWebViewClient` reference (via `WebViewCompat.getWebViewClient`, since the platform `WebView.getWebViewClient()` is API 26+ and the app's `minSdk` is 23) and sets `serverHost = url.host` on each load, so the client always knows which host is the "real" Home Assistant origin. |
| `app/.../onboarding/connection/ConnectionViewModel.kt` | Sets `serverHost` on the **onboarding** web client too, so the same logic applies during first-time setup. |

The patch is a `git format-patch` file, so it preserves the original author, commit message, and diff. **Read it before you trust it** — it is short by design, and that is the point. See [Trust and security](#trust-and-security).

---

## Trust and security

This app holds your **Home Assistant long-lived auth token**. Installing a third-party build of an app like that is a real trust decision, so here is the honest picture:

- **It is debug-signed, with a fixed key.** Releases are signed with a **debug keystore committed to this repo** ([`keystore/debug.keystore`](keystore/debug.keystore)), using the well-known debug credentials (alias `androiddebugkey`, password `android`). That keystore is **public and not secret** by design, so a debug signature proves **nothing** about who built the APK and is **no** supply-chain guarantee — treat the **build process** (below) and the **patch** as the things to verify, not the signature. The reason it's a *fixed* key rather than a throwaway is purely practical: every release is signed identically, so Android installs updates **in place** (no uninstall/reinstall between versions) and you only have to clear Google Play Protect once. (See [Installing](#installing) for the Play Protect steps.)
- **It holds your HA auth token.** The token-bearing JavaScript bridge is the most sensitive surface in the app. This patch is deliberately narrow and is designed to keep that bridge anchored to your real Home Assistant origin, consistent with the hardening direction of [#6733](https://github.com/home-assistant/android/pull/6733). It does not add new token handling.
- **Read the patch.** The complete change is **one short file**: [`patches/0001-auth-proxy-redirect-support.patch`](patches/0001-auth-proxy-redirect-support.patch). Three files, ~61 lines. You can read it in a few minutes. Everything else in any release is **byte-for-byte upstream Home Assistant**.
- **Build it yourself.** You don't have to trust the published APK at all. The [build instructions](#building-it-yourself) let you reproduce a release from the exact upstream commit it names. The workflow that produces releases is in this repo in full — there is nothing hidden.
- **Unaffiliated.** This project is **not affiliated with, endorsed by, or supported by Home Assistant, Nabu Casa, the Open Home Foundation, or any of the proxy/IdP vendors named above.**
- **No warranty.** This is provided **as-is, with no warranty of any kind**. You run it at your own risk. If something breaks, you keep both pieces.

If you're satisfied, head to [Installing](#installing) below. If not, [build it yourself](#building-it-yourself) or wait for upstream/HA core to support auth proxies natively.

---

## Installing

1. **Download the APK** from the **[latest release](../../releases/latest)**. The asset is named:

   ```
   ha-android-authproxy-<VERSION>-g<SHORT>-minimal-debug.apk
   ```

   Each release also publishes a **SHA-256 checksum** (a `.sha256` file and/or in the release body). Verify it before installing:

   ```sh
   sha256sum -c ha-android-authproxy-*.sha256
   # or:
   shasum -a 256 ha-android-authproxy-*-minimal-debug.apk
   ```

2. **Install it.** Two paths — pick whichever suits you. The **on-device** path needs no computer and is the one most people will use.

### Path A — install on the phone (no computer needed)

This is a perfectly normal way to install a sideloaded APK; the only wrinkle is clicking past Google Play Protect, which flags *any* app that didn't come from the Play Store.

1. Get the downloaded APK onto the phone (download it directly on the device, or transfer it via Drive, email, USB, etc.).
2. Open it with a file manager and tap **Install**.
3. The first time, Android asks you to **allow your file manager / browser to install unknown apps** — grant it (Android **Settings → Apps → [that app] → Install unknown apps → Allow**), then go back and tap **Install** again.
4. **Google Play Protect** will interrupt. This is expected for any non-Play app and is **not** a finding that the app is malicious — Play Protect flags the *distribution channel* and the unrecognized signing certificate, not anything the app does. You'll see one of two dialogs:
   - **Soft block** — *"Unsafe app blocked"* / *"App scan recommended"* with a small **More details** link: tap **More details** (not the big **OK**), then **Install anyway**. If it insists on scanning, let it, then choose **Install without scanning** / **Install anyway**.
   - **Hard block** — *"App was blocked to protect your device… can request access to sensitive data"* with **only an OK button and no bypass**. This stronger tier appears for an unrecognized certificate combined with the app's sensitive permissions. There's no in-dialog bypass, so use step 5.
5. **If you got the hard block (OK-only), turn the scanner off for the install:** open the **Play Store app → your profile icon → Play Protect → ⚙ (settings) → turn off "Scan apps with Play Protect"**. Re-open the APK and install it (it goes straight through now), then **turn Play Protect back on**. It will not re-flag the app once it's installed, and because every release here is signed with the **same key**, future updates install over the top **without** another block.

> **Easiest of all, if you have a computer:** [Path B (ADB)](#path-b--install-over-adb-computer--usb) skips the Play Protect dialog entirely — no scanner toggling needed.

### Path B — install over ADB (computer + USB)

If you have the Android platform-tools and USB debugging enabled, this is the fastest repeatable path and **does not trip the Play Protect dialog**:

```sh
adb install -r ha-android-authproxy-<VERSION>-g<SHORT>-minimal-debug.apk
```

The `-r` reinstalls/upgrades in place, preserving the app's data.

> **Why the Play Protect warning happens at all:** this APK is **debug-signed** (with the public, universal Android debug key) rather than signed by a registered Play developer, and it didn't come from the Play Store. Play Protect warns on every such app. The warning speaks to the *distribution channel*, not to anything the app does — which is why [Trust and security](#trust-and-security) (above) covers how to read the patch and build it yourself.

### It coexists with the Play Store app

You **do not** have to uninstall the official app. The **minimal / debug** build uses an `applicationId` with the suffix **`.minimal.debug`**, so it installs as a **separate package** alongside a Play Store or F-Droid install. You can keep your normal Home Assistant app and use this one only for the proxied connection. (Because it's a separate package, it has its own separate app data — you'll onboard it independently.)

---

## Versioning

Release names are derived so that you can always see **which upstream version** and **which upstream commit** a build came from.

- **`<VERSION>`** — the upstream human version, parsed from the first `<release version="YYYY.M.P - Main" …>` entry in upstream `app/src/main/res/xml/changelog_master.xml` (e.g. `2026.6.5`).
- **`<SHORT>`** — the first 7 characters of the upstream `main` commit SHA that was built.

These combine into:

| Thing | Format | Example |
| --- | --- | --- |
| Git tag | `v<VERSION>-authproxy-g<SHORT>` | `v2026.6.5-authproxy-g63b0639` |
| Release title | `Home Assistant <VERSION> + auth-proxy (upstream <SHORT>)` | `Home Assistant 2026.6.5 + auth-proxy (upstream 63b0639)` |
| APK asset | `ha-android-authproxy-<VERSION>-g<SHORT>-minimal-debug.apk` | `ha-android-authproxy-2026.6.5-g63b0639-minimal-debug.apk` |

So a tag like `v2026.6.5-authproxy-g63b0639` means: **Home Assistant 2026.6.5**, built from upstream commit **`63b0639`**, with the auth-proxy patch applied.

---

## How to get notified of new releases

To be alerted when a new build is published (and **only** then, not for every commit or issue):

1. Click **Watch** at the top of this repository.
2. Choose **Custom**.
3. Tick **Releases**.
4. Save.

You'll get a notification each time the auto-build publishes a new release.

---

## Building it yourself

You can rebuild any release locally from the exact source it was made from — the upstream commit named in its tag, plus the one patch in this repo. This is the strongest way to trust a build: you compile it yourself from code you can read, so you don't have to trust the published APK at all. (Your APK will **not** be byte-identical to ours, and that's expected — see [below](#why-your-apk-wont-match-our-sha-256-and-thats-fine).)

### Prerequisites

- **JDK 21** (Temurin recommended)
- **Android SDK** with `sdkmanager`
- **git**
- The build targets `minSdk` 23 / `compileSdk` 37 (resolved from upstream config); the toolchain above covers them.

### Steps

```sh
# 1. Pick the upstream SHA from the release you want to reproduce.
#    It's the <SHORT> in the tag, e.g. v2026.6.5-authproxy-g63b0639 -> 63b0639
UPSTREAM_SHA=63b0639

# 2. Clone upstream WITH TAGS (reckon needs them) and check out that commit.
git clone https://github.com/home-assistant/android.git ha-upstream
cd ha-upstream
git fetch --tags
git checkout "$UPSTREAM_SHA"

# 3. Apply the patch from THIS repo with a 3-way merge.
#    git am consumes the format-patch file and creates a commit preserving authorship:
git am --3way /path/to/ha-android-authproxy/patches/0001-auth-proxy-redirect-support.patch
#    If you only need a buildable tree and don't care about committing, you can instead
#    apply the diff to the working tree without committing:
#      git apply --3way /path/to/ha-android-authproxy/patches/0001-auth-proxy-redirect-support.patch

# 4. Provide the mock google-services.json (the plugin runs for minimal too).
cp .github/mock-google-services.json app/google-services.json

# 5. Build the FOSS minimal debug APK.
#    Do NOT pass -Preckon.stage=beta locally — that's a CI-only setting. Locally
#    reckon runs in snapshot mode and that stage errors ("Stage beta is not one
#    of: [final, snapshot]"). CI sets it because GitHub defines CI=true, which
#    switches reckon to staged mode.
./gradlew :app:assembleMinimalDebug
```

The APK lands at:

```
app/build/outputs/apk/minimal/debug/app-minimal-debug.apk
```

A clean build is **roughly 60 MB** — about the same as the released APK. It can come out larger (~80 MB) if a previous incremental build left the native debug symbols in `libmicrowakeword.so` unstripped; that's harmless (debug symbols only). It's auto-signed with **your own** machine's Android debug keystore — no signing secret required.

### Why your APK won't match our SHA-256 (and that's fine)

A locally built APK is **not** byte-for-byte identical to the published one, so its SHA-256 **will not match** — this is expected, not a failed build. Every difference is build-environment metadata, not code:

- **Signing key** — your build is signed with *your* machine's debug keystore; ours uses the fixed [`keystore/debug.keystore`](keystore/debug.keystore) committed here. Different certificate → different bytes.
- **Version string** — `reckon` embeds a different version locally (a `…-SNAPSHOT`) than in CI (a `…-beta`).
- **Timestamps, build paths, and native debug-symbol stripping** — all differ between machines.

The published `.sha256` is only for checking that your **download of our APK** arrived intact — it is **not** a reproducibility check. To confirm a release is the same *code* you built, compare the **contents**, not the whole-file hash: the `classes*.dex` (app code), `lib/**/*.so` (native libraries), and the declared permissions all match, apart from the embedded version string and stripped debug symbols.

If you want your build to carry the **same signature** as our releases — so it can even update in place over an installed release — build with the committed keystore via the same init script CI uses:

```sh
AUTHPROXY_KEYSTORE=/path/to/ha-android-authproxy/keystore/debug.keystore \
  ./gradlew :app:assembleMinimalDebug \
  --init-script /path/to/ha-android-authproxy/keystore/signing-override.init.gradle
```

> **CMake / NDK note.** The native `:microwakeword` module needs a specific **CMake** and **NDK** version, pinned in upstream `gradle/libs.versions.toml` as `cmake` and `androidNdk` (at the time of writing, `cmake = "4.1.2"` and `androidNdk = "29.0.14206865"`, but read the file — upstream bumps these). If your build fails with `[CXX1300] CMake '…' was not found`, install the exact versions named there:
>
> ```sh
> sdkmanager --install "cmake;4.1.2" "ndk;29.0.14206865"
> ```
>
> (substitute the values from the upstream `libs.versions.toml` of the commit you're building).

> **The `minimal` flavor** is the FOSS variant with **no Google Play Services** — the same one F-Droid ships, and the right choice for sideloading and de-Googled phones.

---

## How the auto-build works

The workflow at **[`.github/workflows/build-and-release.yml`](.github/workflows/build-and-release.yml)** drives everything. At a high level it:

1. **Checks out this repo** (the patch + scripts).
2. **Resolves upstream's latest `main` SHA** via the GitHub API.
3. **No-op check.** If a release tag for that upstream SHA **already exists** on this repo, it exits `0` without rebuilding — unless the manual **`force`** input is set.
4. **Clones upstream at that SHA *with tags*** (tags are required by the `reckon` versioning plugin, below).
5. **Applies the patch** with a 3-way merge (`scripts/apply-patch.sh`). If it no longer applies cleanly, the workflow **opens/refreshes a GitHub issue** containing the conflict/reject detail and **fails** — see the [contributor section](#for-contributors-updating-the-patch-when-upstream-breaks-it).
6. **Installs the right CMake and NDK.** Both versions are read **dynamically** from upstream `gradle/libs.versions.toml` (`cmake` and `androidNdk`) — *not* hardcoded — and installed via `sdkmanager` (accepting licenses) **before** the Gradle build, so the native `:microwakeword` module builds. This is required because the GitHub-hosted runner has the Android SDK but not the pinned CMake, and the build otherwise fails with `[CXX1300] CMake '…' was not found`.
7. **Provides a mock `google-services.json`.** The `google-services` Gradle plugin runs even for the FOSS `minimal` flavor and fails if the file is missing, so upstream's `.github/mock-google-services.json` is copied to `app/google-services.json` (module-root location, covering all flavor/buildType combos).
8. **Builds** `:app:assembleMinimalDebug` with **JDK 21** and `-Preckon.stage=beta` (see note below).
9. **Renames the APK**, computes the version + tag, generates release notes, and creates the GitHub Release with the APK and its SHA-256 checksum, marked as **latest**.

**Triggers:** a daily `schedule` (a quiet UTC hour, to pick up upstream changes), `workflow_dispatch` (with the `force` boolean to rebuild even when unchanged), and `push` to this repo's `main` (so editing the patch rebuilds). A **concurrency group** prevents overlapping runs.

**Permissions:** the minimum needed — `contents: write` (create the tag/release) and `issues: write` (alert on patch failure). It uses the built-in `GITHUB_TOKEN`; no personal access token is required, since everything is on this repo plus public read of upstream.

> **Note on `reckon`:** upstream's `reckon` Gradle plugin computes the project version from git tags, and in CI (where the `CI` env var is present, as GitHub Actions sets it) it selects a staged scheme that **requires** a *stage*. Passing `-Preckon.stage=beta` satisfies it. Unsetting `CI` does **not** help — Gradle sees the variable as present even when empty (`environmentVariable("CI").isPresent` is `true`). This is also why the upstream clone must include tags: reckon needs an existing tag as its base version. The resulting reckon version string is irrelevant here; release names come from the [versioning](#versioning) scheme above.

### Enabling the workflow (first run)

When you first create this repository, GitHub registers the `schedule` and `workflow_dispatch` triggers only once the workflow file is present on the **default branch** (`main`). After the initial push:

1. Open the **Actions** tab.
2. Select the **build-and-release** workflow.
3. Click **Run workflow** (this is `workflow_dispatch`) to produce the first release immediately, rather than waiting for the next scheduled run.

On a brand-new repo there are no releases yet, so the no-op check finds nothing and the first run always builds. After that, the daily schedule takes over and only builds when upstream `main` advances (or when you push a patch change).

---

## For contributors: updating the patch when upstream breaks it

Because the patch is applied on top of a **moving** upstream `main`, upstream will eventually refactor one of the three touched files and the patch will stop applying. When that happens the auto-build **opens (or refreshes) a GitHub issue** with the conflict/reject output and fails — that's the signal to update the patch.

To refresh it:

```sh
# 1. Clone upstream at the SHA from the failing run (in the issue), with tags.
git clone https://github.com/home-assistant/android.git ha-upstream
cd ha-upstream
git fetch --tags
git checkout <failing-upstream-sha>

# 2. Try the patch and let the 3-way merge mark the conflicts.
#    Use git am here (not git apply): it creates a commit, which step 3 regenerates from.
git am --3way /path/to/patches/0001-auth-proxy-redirect-support.patch
#    If git am stops on conflicts, resolve them in the three Kotlin files
#    (see "Exactly what is modified"), then: git add -A && git am --continue

# 3. Once it applies and builds, regenerate the patch preserving authorship.
git format-patch -1 --stdout > /path/to/patches/0001-auth-proxy-redirect-support.patch
```

Keep the change **minimal** and confined to the same three files where possible:

- `util/TLSWebViewClient.kt`
- `webview/WebViewActivity.kt`
- `onboarding/connection/ConnectionViewModel.kt`

Commit the regenerated patch to this repo's `main`; the `push` trigger rebuilds and, if green, publishes a fresh release. Helper scripts you'll find useful:

- **`scripts/apply-patch.sh`** — applies the patch to a checked-out upstream tree with a 3-way merge; exits non-zero with the conflict detail on failure.
- **`scripts/derive-version.sh`** — echoes the upstream `YYYY.M.P` version from `changelog_master.xml`.

---

## Why this isn't in Home Assistant core (and may not ever be)

*Background — not required to use the app. Skip it if you just want the build working; read on if you want to understand why this repo has to exist.*

As noted earlier, the "right" way to do this — get the Android companion app to work behind an OIDC/OAuth2 auth proxy — was [proposed upstream](https://github.com/home-assistant/android/pull/6725) and turned down (along with the [security hardening](https://github.com/home-assistant/android/pull/6733) that would have accompanied it). That's not a conspiracy, and this section isn't a complaint. It's an attempt to explain the situation honestly so you can set realistic expectations.

### What the maintainers actually said

Two pull requests against the Android app were closed, not merged. In [home-assistant/android#6725](https://github.com/home-assistant/android/pull/6725), maintainer TimoPtr closed the feature with:

> "All of these tickets are being closed because we are not planning to add support for external authentication providers at the Android app level. This is a broader architectural concern that needs to be addressed at the Home Assistant core level rather than within a single client... support for standards like OIDC would need to be implemented in core first and then leveraged by clients, including Android."

He also cited WebView attack surface (the JavaScript bridge that carries auth tokens) and noted mTLS and VPN as the recommended paths. A second PR, [home-assistant/android#6733](https://github.com/home-assistant/android/pull/6733), hardened that token-bearing bridge — and was *also* declined, on the grounds that it is "only relevant if we ever allow loading an url that is not Home Assistant." In other words: fix the client only after core leads, and core hasn't.

### The architectural reason

"Do it in core first" is a real ask, not a deflection. Core today documents exactly three auth providers — `homeassistant` (local username/password), `trusted_networks` (an IP allowlist), and `command_line` ([docs](https://www.home-assistant.io/docs/authentication/providers/)). None is an external-IdP or OIDC client. Core's auth is built on OAuth2 plus IndieAuth, where credentials are validated *only at login*; after that, a refresh/access-token pair is issued and subsequent requests rely on those tokens without re-checking any upstream provider ([auth API](https://developers.home-assistant.io/docs/auth_api/)).

That design produces the maintainers' most-cited objection. As quoted in [architecture#832](https://github.com/home-assistant/architecture/issues/832), balloob (Paulus Schoutsen) asked "how do we want to deal with users that are no longer allowed to log in?" — because a user disabled at an external IdP can stay authenticated until their token expires (access tokens last 30 minutes, but long-lived tokens last 10 years). Earlier core PRs to add OpenID Connect ([#32926](https://github.com/home-assistant/core/pull/32926)) and LDAP ([#37645](https://github.com/home-assistant/core/pull/37645)) were both closed unmerged, with balloob noting "Every bug could end up with a system that can be accessed unauthorized." The other recurring theme is ownership: when a header-auth PR ([#38175](https://github.com/home-assistant/core/pull/38175)) was proposed, balloob declined it because "the moment we accept this PR, it becomes our responsibility." Bolting a federated IdP onto this single-client token model isn't a small patch — it would mean rethinking how and when core re-validates identity.

### The philosophical reason

Home Assistant and the Open Home Foundation are explicitly local-first and privacy-first. The Foundation's values are privacy, choice, and sustainability, and the [Open Home manifesto](https://www.home-assistant.io/blog/2021/12/23/the-open-home/) states "Devices need to work locally" and that a cloud connection "should be extra and opt-in." Schoutsen's ["Local = Reliable"](https://newsletter.openhomefoundation.org/local-equals-reliable/) argues that "your smart home shouldn't be beholden to anything outside of your home to function."

A federated or cloud identity provider is, structurally, exactly the kind of external dependency that stance is wary of. Maintainer frenck made the connection directly in [architecture#832](https://github.com/home-assistant/architecture/issues/832): external auth "works a little against the core values (local vs remote in auth)," adding "I am pretty sure my dad... isn't using SSO to log in to his home devices." *(Inference, clearly labeled: I read the reluctance as a coherent extension of the local-first philosophy rather than indifference — though note other commenters in that same thread disputed the "average user" framing, pointing out that plenty of self-hosters do run Keycloak or Authentik at home.)*

### Speculation (clearly labeled)

Here's the part that is *my read, not a documented fact.* Home Assistant's officially recommended remote-access path is Home Assistant Cloud (Nabu Casa), which sells secure remote access without opening ports (a low monthly subscription) and whose subscriptions, by the project's own [docs](https://www.home-assistant.io/docs/configuration/securing/), "help fund the development of Home Assistant itself" and support the Open Home Foundation. Speculatively, a project whose blessed remote-access path is also its funding model may have weaker incentive to make DIY reverse-proxy + OIDC setups first-class.

I want to be explicit: **this is speculation, not evidence of bad faith.** No source asserts a revenue motive, no documented Nabu Casa product gates HA behind an external auth proxy, and the stated technical reasons — token revocation, attack surface, maintenance ownership — may be the whole story. They are coherent and sufficient on their own.

### Takeaway

That's why this repo exists: to give self-hosters the OIDC-proxy path that core doesn't natively support today — and it would become unnecessary the day Home Assistant core ships a first-class external-IdP/OIDC auth provider that the clients can simply use.

---

## Disclaimers and attribution

- **Home Assistant Android** is © its contributors and licensed under the **Apache License 2.0**. The upstream source lives at **[home-assistant/android](https://github.com/home-assistant/android)**. Every release here is upstream's code plus the single patch in this repo; the upstream `LICENSE` and `NOTICE` apply to that code unchanged.
- This repository's **own** added files — the patch, helper scripts, the workflow, and this README — are offered under the **Apache License 2.0** (see [`LICENSE`](LICENSE)), compatible with upstream. (MIT is an acceptable alternative for these files if a maintainer prefers.)
- This project is **independent and unaffiliated** with Home Assistant, **Nabu Casa**, the Open Home Foundation, **Google**, **Microsoft**, **Cloudflare**, or any other vendor named here. All trademarks belong to their respective owners.
- Provided **as-is, without warranty of any kind**. Use at your own risk. See [Trust and security](#trust-and-security).
