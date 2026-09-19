#!/usr/bin/env python3
"""Sign iOS project: patch pbxproj, build ExportOptions.plist, archive, export."""
import os
import plistlib
import re
import subprocess
import sys

def main():
    runner_temp = os.environ['RUNNER_TEMP']
    team_id = os.environ['TEAM_ID']
    pp_path = os.environ['PP_PATH']
    keychain_path = os.environ['KEYCHAIN_PATH']

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
    app_id = pp_data.get('Entitlements', {}).get('application-identifier', '')
    print(f"Profile name: {profile_name}")
    print(f"Profile UUID: {profile_uuid}")
    print(f"Profile app-id: {app_id}")
    print(f"Team ID: {team_id}")

    # Patch project.pbxproj
    pbxproj_path = 'ios/Runner.xcodeproj/project.pbxproj'
    with open(pbxproj_path, 'r') as f:
        content = f.read()

    # Replace Automatic with Manual
    content = content.replace('CODE_SIGN_STYLE = Automatic;', 'CODE_SIGN_STYLE = Manual;')

    # Remove any existing DEVELOPMENT_TEAM or PROVISIONING_PROFILE_SPECIFIER
    content = re.sub(r'\t+DEVELOPMENT_TEAM = "[^"]*";\n?', '', content)
    content = re.sub(r'\t+PROVISIONING_PROFILE_SPECIFIER = "[^"]*";\n?', '', content)

    # Find all build config sections with CODE_SIGN_STYLE = Manual
    # and inject DEVELOPMENT_TEAM + PROVISIONING_PROFILE_SPECIFIER after each
    marker = 'CODE_SIGN_STYLE = Manual;'
    insert_block = f'\n\t\t\t\tDEVELOPMENT_TEAM = {team_id};\n'
    if profile_uuid:
        insert_block += f'\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profile_uuid}";\n'

    content = content.replace(marker, marker + insert_block)

    with open(pbxproj_path, 'w') as f:
        f.write(content)

    # Verify the patch worked
    with open(pbxproj_path, 'r') as f:
        patched = f.read()
    team_count = patched.count(f'DEVELOPMENT_TEAM = {team_id};')
    spec_count = patched.count('PROVISIONING_PROFILE_SPECIFIER')
    manual_count = patched.count('CODE_SIGN_STYLE = Manual;')
    print(f"Patched: {manual_count} Manual, {team_count} DEVELOPMENT_TEAM, {spec_count} PROVISIONING_PROFILE_SPECIFIER")

    if team_count == 0:
        print("ERROR: DEVELOPMENT_TEAM not found after patch!")
        sys.exit(1)

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
    print(f"ExportOptions.plist created with profile: {profile_name}")

    # Archive
    archive_path = os.path.join(runner_temp, 'Runner.xcarchive')
    ipa_path = os.path.join(runner_temp, 'ipa')

    archive_cmd = [
        'xcodebuild', '-workspace', 'ios/Runner.xcworkspace',
        '-scheme', 'Runner', '-configuration', 'Release',
        '-archivePath', archive_path,
        '-destination', 'generic/platform=iOS',
        '-allowProvisioningUpdates',
        f'OTHER_CODE_SIGN_FLAGS=--keychain {keychain_path}',
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
