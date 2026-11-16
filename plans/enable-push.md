# Turn iOS push back on

## Why it's off

`4fe9021` (Add Telegram APNs registration) signed `App/Config/iOS.entitlements` into the
iOS app. That file holds `aps-environment` (`production` for Release). The App ID
`com.milestonemade.winston` doesn't have the Push Notifications capability, so no
provisioning profile includes `aps-environment`:

- Xcode Cloud archived fine, but "Exporting for App Store Distribution" failed for every
  build from 39 on. Build 39 was the first build to include `4fe9021`.
- Locally, a signed Release archive fails with: `Provisioning profile "iOS Team
  Provisioning Profile: *" doesn't include the aps-environment entitlement.` The only
  local profile is the wildcard, and a wildcard App ID can't have Push.

For now `App/Config/Shared.xcconfig` leaves out `CODE_SIGN_ENTITLEMENTS`, so builds have
no entitlements file. The APNs code still builds and runs: iOS turns down the token
request, `didFailToRegisterForRemoteNotificationsWithError` marks registration failed,
and Settings → Notifications shows "Couldn't connect" with Retry.

## Steps

Do them in this order. Turning the entitlement back on before the App ID has the
capability breaks the export again.

### 1. Developer portal: add the capability

1. Go to <https://developer.apple.com/account> → Certificates, IDs & Profiles →
   Identifiers → `com.milestonemade.winston`.
2. On the Capabilities tab, check **Push Notifications** and Save. Confirm when the portal
   warns that the profiles for this App ID become invalid.

App Store Connect needs no change: push is a capability of the App ID, not of the
App Store Connect app record.

### 2. Refresh the provisioning profiles

- **Xcode Cloud** uses cloud-managed automatic signing. It should make new profiles,
  with `aps-environment`, on the next build, so there is nothing to do by hand.
- **This Mac:** on 2026-11-16 `xcodebuild` reported the saved Xcode account as invalid
  (`missing Xcode-Username`). Sign in again in Xcode → Settings → Accounts. Then build the
  app to an iPhone with automatic signing, so Xcode creates `iOS Team Provisioning
  Profile: com.milestonemade.winston` with Push. The wildcard profile can never carry it.

### 3. APNs certificate for Telegram

Telegram, not Winston, sends the alerts, so it needs the APNs credentials. See README →
iOS push notifications → Provider and signing setup, step 2:

1. In the portal, go to Certificates → + → **Apple Push Notification service SSL (Sandbox
   & Production)**, pick `com.milestonemade.winston`, and upload a certificate signing
   request from Keychain Access.
2. Download the certificate and export it with its private key, as PEM containing both.
3. Upload it to the Telegram application that owns `TG_API_ID`, at
   <https://my.telegram.org/apps>. Keep it out of the app and the repository.

### 4. Repository: sign the entitlement back in

1. In `App/Config/Shared.xcconfig`, replace the "Push is off" comment with:

   ```
   CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*] = Config/iOS.entitlements
   CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*] = Config/iOS.entitlements
   ```

2. In `README.md`, remove the "Push is off for now" note at the top of iOS push
   notifications and the "Turning push back on" section. Reword Provider and signing
   setup step 1 to say the App ID has Push Notifications and the iOS target signs in
   `aps-environment`. Then delete this file.

### 5. Check it locally

A signed Release archive must succeed, and its app must carry the entitlement:

```sh
xcodebuild archive -project App/Winston.xcodeproj -scheme Winston -configuration Release \
  -destination generic/platform=iOS -derivedDataPath DerivedData \
  -archivePath DerivedData/Archives/Winston-iOS.xcarchive
codesign -d --entitlements - \
  DerivedData/Archives/Winston-iOS.xcarchive/Products/Applications/Winston.app
```

The second command should print `aps-environment`. To check the App Store export the way
Xcode Cloud runs it, write an `ExportOptions.plist` with `method` = `app-store-connect`,
`signingStyle` = `automatic`, and `teamID` = `T68Z94627S`. Then run:

```sh
xcodebuild -exportArchive -archivePath DerivedData/Archives/Winston-iOS.xcarchive \
  -exportPath DerivedData/Export -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates
```

`-allowProvisioningUpdates` lets Xcode create the App Store profile in the developer
account. The exported app's `aps-environment` must be `production`, matching the
`TelegramPushEnvironment` in its Info.plist.

### 6. Check it on Xcode Cloud and a device

1. Push, and check that the iOS archive's "Exporting for App Store Distribution" step
   passes and the build reaches TestFlight. If it fails, download the logs artifact and
   look in `xcodebuild-export-archive.log` for a `doesn't include ... entitlement` line.
2. Follow README → Provider and signing setup, step 4: install the build on an iPhone,
   log in, enable notifications, put Winston in the background, and send a message from an
   unmuted bot. Settings → Notifications should say Enabled, not "Couldn't connect".
