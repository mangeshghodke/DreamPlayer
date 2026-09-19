#!/usr/bin/env python3
"""Sign iOS project: patch PROVISIONING_PROFILE_SPECIFIER in pbxproj only,
archive with command-line signing flags, export."""
import os
import plistlib
import re
import subprocess
import sys

def main():
    runner_temp = os.environ['RUNNER_TEMP']
    team_id = os.environ.get('TEAM_ID', '').strip()
    pp_path = os.environ['PP_PATH']
    keychain_path = os.environ['KEYCHAIN_PATH']

    if not team_id:
        print("ERROR: TEAM_ID is empty! Set APPSTORE_TEAM_ID secret.")
        sys.exit(1)

    # Decode provisioning profile
    result = subprocess.run(
        ['security', 'cms', '-D', '-i', pp_path],
        capture_output=True
    )
    if result.returncode != 0:
        print(f"ERROR: security cms failed: {result.stderr.decode()}")
        sys.exit(1)

    pp_data = plistlib.loads(result.stdout)
    profile_name = pp_data.get('Name', 'DreamPlayer AppStore')
    profile_uuid = pp_data.get('UUID', '')
    print(f"Profile name: {profile_name}")
    print(f"Profile UUID: {profile_uuid}")
    print(f"Team ID: {team_id}")

    # Patch PROVISIONING_PROFILE_SPECIFIER into Runner target only in pbxproj
    # This avoids leaking it to SPM targets via command line
    pbxproj_path = 'ios/Runner.xcodeproj/project.pbxproj'
    with open(pbxproj_path, 'r') as f:
        content = f.read()

    # Remove any existing PROVISIONING_PROFILE_SPECIFIER lines
    content = re.sub(r'\t+PROVISIONING_PROFILE_SPECIFIER = "[^"]*";\n?', '', content)

    # Add PROVISIONING_PROFILE_SPECIFIER after CODE_SIGN_STYLE in Runner target configs
    # Runner target has PRODUCT_BUNDLE_IDENTIFIER = com.dreamplayer.app;
    # We add it right before PRODUCT_BUNDLE_IDENTIFIER in those configs
    marker = 'PRODUCT_BUNDLE_IDENTIFIER = com.dreamplayer.app;'
    insert = f'\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profile_name}";\n{marker}'
    # Only replace in Runner target configs (not RunnerTests which has .RunnerTests suffix)
    # Runner configs have PRODUCT_BUNDLE_IDENTIFIER = com.dreamplayer.app; (no .RunnerTests)
    content = content.replace(marker, insert)

    with open(pbxproj_path, 'w') as f:
        f.write(content)

    # Verify
    with open(pbxproj_path, 'r') as f:
        patched = f.read()
    spec_count = patched.count('PROVISIONING_PROFILE_SPECIFIER')
    print(f"Patched: {spec_count} PROVISIONING_PROFILE_SPECIFIER in Runner target")

    # Build ExportOptions.plist
    export_opts = {
        'method': 'app-store',
        'teamID': team_id,
        'signingStyle': 'manual',
        'provisioningProfiles': {
            'com.dreamplayer.app': profile_name,
        },
    }
    export_opts_path = os.path.join(runner_temp, 'ExportOptions.plist')
    with open(export_opts_path, 'wb') as f:
        plistlib.dump(export_opts, f)

    # Clean DerivedData
    derived_data = os.path.join(runner_temp, 'DerivedData')
    subprocess.run(['rm', '-rf', derived_data], check=False)

    # Archive — PROVISIONING_PROFILE_SPECIFIER is NOT on the command line
    # (it's in pbxproj for Runner only, avoiding SPM target leakage)
    archive_path = os.path.join(runner_temp, 'Runner.xcarchive')
    ipa_path = os.path.join(runner_temp, 'ipa')

    archive_cmd = [
        'xcodebuild', '-workspace', 'ios/Runner.xcworkspace',
        '-scheme', 'Runner', '-configuration', 'Release',
        '-archivePath', archive_path,
        '-derivedDataPath', derived_data,
        '-destination', 'generic/platform=iOS',
        '-allowProvisioningUpdates',
        f'OTHER_CODE_SIGN_FLAGS=--keychain {keychain_path}',
        'CODE_SIGN_STYLE=Manual',
        f'DEVELOPMENT_TEAM={team_id}',
        'CODE_SIGN_IDENTITY=Apple Distribution',
        'archive',
    ]
    print(f"Running: {' '.join(archive_cmd)}")
    ret = subprocess.run(archive_cmd)
    if ret.returncode != 0:
        print(f"ERROR: xcodebuild archive failed with code {ret.returncode}")
        sys.exit(ret.returncode)

    # Export
    export_cmd = [
        'xcodebuild', '-exportArchive',
        '-archivePath', archive_path,
        '-exportPath', ipa_path,
        '-exportOptionsPlist', export_opts_path,
    ]
    print(f"Running: {' '.join(export_cmd)}")
    ret = subprocess.run(export_cmd)
    if ret.returncode != 0:
        print(f"ERROR: xcodebuild export failed with code {ret.returncode}")
        sys.exit(ret.returncode)

    print("Build complete!")

if __name__ == '__main__':
    main()
