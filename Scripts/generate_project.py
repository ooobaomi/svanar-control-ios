"""Generate a dependency-free, shared-scheme Xcode project on any OS."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = os.environ.get('BUNDLE_ID', 'io.local.svanarcontrol')
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', BUNDLE):
    raise SystemExit('Invalid BUNDLE_ID')


def uid(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()


def q(value):
    return json.dumps(value)


def build():
    sources = sorted(p.name for p in (ROOT / 'App').glob('*.swift'))
    objects = []

    def add(label, content):
        objects.append(f'\t\t{uid(label)} = {{ {content} }};')

    for name in sources:
        add('ref:' + name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(name)}; sourceTree = "<group>";')
        add('build:' + name, f'isa = PBXBuildFile; fileRef = {uid("ref:" + name)};')
    add('ref:assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
    add('build:assets', f'isa = PBXBuildFile; fileRef = {uid("ref:assets")};')
    add('ref:product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SvanarControl.app; sourceTree = BUILT_PRODUCTS_DIR;')
    add('group:app', 'isa = PBXGroup; path = App; sourceTree = "<group>"; children = (' +
        ','.join(uid('ref:' + name) for name in sources) + ',' + uid('ref:assets') + ',);')
    add('group:products', f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({uid("ref:product")},);')
    add('group:root', f'isa = PBXGroup; sourceTree = "<group>"; children = ({uid("group:app")},{uid("group:products")},);')
    add('phase:sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' +
        ','.join(uid('build:' + name) for name in sources) + ',); runOnlyForDeploymentPostprocessing = 0;')
    add('phase:frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    add('phase:resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("build:assets")},); runOnlyForDeploymentPostprocessing = 0;')
    for config in ('Debug', 'Release'):
        debug = config == 'Debug'
        settings = {
            'ALWAYS_SEARCH_USER_PATHS': 'NO', 'CLANG_ENABLE_MODULES': 'YES',
            'CLANG_ENABLE_OBJC_ARC': 'YES', 'IPHONEOS_DEPLOYMENT_TARGET': '16.0',
            'SDKROOT': 'iphoneos', 'SWIFT_VERSION': '5.0',
            'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if debug else '-O',
            'SWIFT_COMPILATION_MODE': 'singlefile' if debug else 'wholemodule',
            'DEBUG_INFORMATION_FORMAT': 'dwarf' if debug else 'dwarf-with-dsym',
            'ENABLE_NS_ASSERTIONS': 'YES' if debug else 'NO',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if debug else '',
        }
        add('config:project:' + config, 'isa = XCBuildConfiguration; name = ' + config + '; buildSettings = {' +
            ''.join(f'{key} = {q(value)};' for key, value in settings.items()) + '};')
        app_settings = {
            'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE, 'PRODUCT_NAME': '$(TARGET_NAME)',
            'INFOPLIST_FILE': 'App/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
            'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
            'CODE_SIGN_STYLE': 'Automatic', 'TARGETED_DEVICE_FAMILY': '1,2',
            'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST': 'NO',
            'CURRENT_PROJECT_VERSION': '1', 'MARKETING_VERSION': '1.0.0',
            'ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES': 'YES',
            'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
        }
        add('config:target:' + config, 'isa = XCBuildConfiguration; name = ' + config + '; buildSettings = {' +
            ''.join(f'{key} = {q(value)};' for key, value in app_settings.items()) + '};')
    for category in ('project', 'target'):
        add('configs:' + category, 'isa = XCConfigurationList; buildConfigurations = (' +
            ','.join(uid('config:' + category + ':' + c) for c in ('Debug', 'Release')) +
            ',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    add('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("configs:target")}; ' +
        f'buildPhases = ({uid("phase:sources")},{uid("phase:frameworks")},{uid("phase:resources")},); ' +
        'buildRules = (); dependencies = (); name = SvanarControl; productName = SvanarControl; ' +
        f'productReference = {uid("ref:product")}; productType = "com.apple.product-type.application";')
    add('project', f'isa = PBXProject; buildConfigurationList = {uid("configs:project")}; ' +
        'attributes = { LastUpgradeCheck = 1600; LastSwiftUpdateCheck = 1600; }; ' +
        'compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; ' +
        'knownRegions = (en,"zh-Hans",Base,); ' +
        f'mainGroup = {uid("group:root")}; productRefGroup = {uid("group:products")}; ' +
        f'projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},);')
    project = ROOT / 'SvanarControl.xcodeproj'
    project.mkdir(exist_ok=True)
    (project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' +
        '\n'.join(objects) + f'\n\t}};\n\trootObject = {uid("project")};\n}}\n', encoding='utf-8')
    schemes = project / 'xcshareddata' / 'xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="SvanarControl.app" BlueprintName="SvanarControl" ReferencedContainer="container:SvanarControl.xcodeproj"/>'
    (schemes / 'SvanarControl.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
 <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding='utf-8')
    info = {
        'CFBundleDevelopmentRegion': 'zh_CN', 'CFBundleDisplayName': 'SVANAR Control',
        'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': '$(PRODUCT_NAME)', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)',
        'LSRequiresIPhoneOS': True, 'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'NSBluetoothAlwaysUsageDescription': '通过蓝牙读取并调节你的 SVANAR 耳机模式、10 段 EQ 与电量。',
        'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
                                               'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
        'ITSAppUsesNonExemptEncryption': False,
    }
    with (ROOT / 'App' / 'Info.plist').open('wb') as handle:
        plistlib.dump(info, handle, sort_keys=False)
    print(f'Generated SvanarControl.xcodeproj ({len(sources)} Swift files, {BUNDLE})')


if __name__ == '__main__':
    build()
