#!/usr/bin/env python3
"""Sign and build iOS IPA: patch Runner target signing in pbxproj, then flutter build ipa."""
import os
import plistlib
import re
import subprocess
import sys

def main():
    runner_temp = os.environ['RUNNER_TEMP']
    team_id = os.environ.get('TEAM_ID', '').strip()
    pp_path = os.environ['PP_PATH']

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
    print(f"Profile name: {profile_name}")
    print(f"Team ID: {team_id}")

    # Patch Runner target build settings in pbxproj
    # flutter build ipa reads signing from the project, so we must set it there.
    # We do NOT set PROVISIONING_PROFILE_SPECIFIER via cmdline (leaks to SPM).
    pbxproj_path = 'ios/Runner.xcodeproj/project.pbxproj'
    with open(pbxproj_path, 'r') as f:
        content = f.read()

    # Strip any existing signing settings
    content = re.sub(r'\t+CODE_SIGN_STYLE = [^;]+;\n?', '', content)
    content = re.sub(r'\t+DEVELOPMENT_TEAM = "[^"]*";\n?', '', content)
    content = re.sub(r'\t+DEVELOPMENT_TEAM = [A-Z0-9]+;\n?', '', content)
    content = re.sub(r'\t+PROVISIONING_PROFILE_SPECIFIER = "[^"]*";\n?', '', content)
    content = re.sub(r'\t+CODE_SIGN_IDENTITY = "[^"]*";\n?', '', content)

    # Add signing settings to every Runner target config.
    # Runner target configs have PRODUCT_BUNDLE_IDENTIFIER = com.dreamplayer.app;
    # (RunnerTests has com.dreamplayer.app.RunnerTests — won't match the semicolon)
    signing_block = (
        f'\t\t\t\tCODE_SIGN_STYLE = Manual;\n'
        f'\t\t\t\tCODE_SIGN_IDENTITY = "Apple Distribution";\n'
        f'\t\t\t\tDEVELOPMENT_TEAM = "{team_id}";\n'
        f'\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profile_name}";\n'
    )
    marker = '\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.dreamplayer.app;'
    content = content.replace(marker, signing_block + marker)

    with open(pbxproj_path, 'w') as f:
        f.write(content)

    # Verify
    with open(pbxproj_path, 'r') as f:
        patched = f.read()
    spec_count = patched.count('PROVISIONING_PROFILE_SPECIFIER')
    dev_count = patched.count(f'DEVELOPMENT_TEAM = "{team_id}"')
    print(f"Patched: {dev_count} DEVELOPMENT_TEAM, {spec_count} PROVISIONING_PROFILE_SPECIFIER")

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

    # flutter build ipa handles plugin resolution, registrant generation,
    # and passes signing settings to xcodebuild correctly.
    cmd = [
        'flutter', 'build', 'ipa', '--release',
        '--export-options-plist', export_opts_path,
        '--dart-define=PAYWALL_ENABLED=true',
    ]

    # Pass dart-defines from env (TMDB_API_KEY etc.)
    for key in ('TMDB_API_KEY', 'OPENSUBTITLES_API_KEY', 'SIMKL_CLIENT_ID'):
        val = os.environ.get(key, '').strip()
        if val:
            cmd.append(f'--dart-define={key}={val}')
    print(f"Running: {' '.join(cmd)}")
    ret = subprocess.run(cmd)
    if ret.returncode != 0:
        print(f"ERROR: flutter build ipa failed with code {ret.returncode}")
        sys.exit(ret.returncode)

    print("Build complete!")

if __name__ == '__main__':
    main()
