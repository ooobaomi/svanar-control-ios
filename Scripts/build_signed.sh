#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${IOS_CERT_P12_BASE64:?Set IOS_CERT_P12_BASE64 in repository Actions secrets}"
: "${IOS_PROFILE_BASE64:?Set IOS_PROFILE_BASE64 in repository Actions secrets}"
export IOS_CERT_PASSWORD="${IOS_CERT_PASSWORD:-}"
temp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/svanar-sign.XXXXXX")"
export SIGN_TEMP="$temp"
keychain="$temp/sign.keychain-db"
keypass="$(openssl rand -base64 32)"
profile_path=''
profile_path_new=''
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  if [[ -f "$temp/keychain-list.txt" ]]; then
    python3 - <<'PY' || true
import os,shlex,subprocess
from pathlib import Path
p=Path(os.environ['SIGN_TEMP'])/'keychain-list.txt'
subprocess.run(['security','list-keychains','-d','user','-s',*shlex.split(p.read_text())],check=True)
PY
  fi
  [[ -z "$profile_path" ]] || rm -f "$profile_path"
  [[ -z "$profile_path_new" ]] || rm -f "$profile_path_new"
  rm -rf "$temp"
}
trap cleanup EXIT
python3 - <<'PY'
import base64, os
from pathlib import Path
p=Path(os.environ['SIGN_TEMP'])
for name, secret in [('certificate.p12','IOS_CERT_P12_BASE64'), ('profile.mobileprovision','IOS_PROFILE_BASE64')]:
    value=base64.b64decode(''.join(os.environ[secret].split()), validate=True)
    (p/name).write_bytes(value)
PY
security create-keychain -p "$keypass" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keypass" "$keychain"
security list-keychains -d user > "$temp/keychain-list.txt"
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
security import "$temp/certificate.p12" -P "$IOS_CERT_PASSWORD" -A -t cert -f pkcs12 -k "$keychain" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keypass" "$keychain" >/dev/null
security cms -D -i "$temp/profile.mobileprovision" > "$temp/profile.plist"
python3 - <<'PY'
import os,plistlib,datetime
from pathlib import Path
p=Path(os.environ['SIGN_TEMP'])
profile=plistlib.loads((p/'profile.plist').read_bytes())
bundle=os.environ.get('BUNDLE_ID','io.local.svanarcontrol')
team=profile['TeamIdentifier'][0]
app_id=profile['Entitlements']['application-identifier']
allowed=app_id.split('.',1)[1]
if allowed!=bundle and not (allowed.endswith('.*') and bundle.startswith(allowed[:-1])):
    raise SystemExit('Provisioning profile does not match BUNDLE_ID')
if profile['ExpirationDate']<=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    raise SystemExit('Provisioning profile has expired')
if not profile.get('ProvisionedDevices'):
    raise SystemExit('Use a development or Ad Hoc profile containing your iPhone UDID')
method='debugging' if profile['Entitlements'].get('get-task-allow') else 'release-testing'
for name,value in [('team',team),('uuid',profile['UUID']),('method',method)]:
    (p/name).write_text(value)
options={'method':method,'teamID':team,'signingStyle':'manual',
         'provisioningProfiles':{bundle:profile['UUID']},'stripSwiftSymbols':True}
(p/'ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
team="$(cat "$temp/team")"
uuid="$(cat "$temp/uuid")"
method="$(cat "$temp/method")"
identity="$(security find-identity -v -p codesigning "$keychain" | awk '/[0-9A-F]{40}/ {print $2;exit}')"
if [[ -z "$identity" ]]; then echo 'No valid signing identity in the provided P12' >&2; exit 1; fi
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
profile_path="$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.mobileprovision"
profile_path_new="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$uuid.mobileprovision"
cp "$temp/profile.mobileprovision" "$profile_path"
cp "$temp/profile.mobileprovision" "$profile_path_new"
python3 Scripts/generate_project.py
xcodebuild -project SvanarControl.xcodeproj -scheme SvanarControl -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -archivePath build/SvanarControl.xcarchive \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="$uuid" \
  CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="--keychain $keychain" \
  archive 2>&1 | tee build/archive.log
xcodebuild -exportArchive -archivePath build/SvanarControl.xcarchive \
  -exportPath build/export -exportOptionsPlist "$temp/ExportOptions.plist" \
  2>&1 | tee build/export.log
test -f build/export/SvanarControl.ipa
mkdir -p artifacts
cp build/export/SvanarControl.ipa artifacts/SvanarControl-signed.ipa
shasum -a 256 artifacts/SvanarControl-signed.ipa >> artifacts/SHA256SUMS.txt
printf '%s\n' "Signed IPA exported ($method). Install only on devices listed in the provisioning profile." >> artifacts/BUILD-STATUS.txt
