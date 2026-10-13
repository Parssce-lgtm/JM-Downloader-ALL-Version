"""Generate a dependency-free Xcode project with stable identifiers."""
from pathlib import Path
import hashlib
import plistlib

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, value):
    key = ident(name)
    objects[key] = value
    return key
def ref(path, kind):
    return add('file:' + path, dict(isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>'))
def configs(name, settings):
    ids = []
    for mode in ['Debug', 'Release']:
        build = dict(settings)
        build['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if mode == 'Debug' else '-O'
        if mode == 'Debug':
            build['ENABLE_TESTABILITY'] = 'YES'
            build['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        ids.append(add(name + mode, dict(isa='XCBuildConfiguration', name=mode, buildSettings=build)))
    return add(name + 'configs', dict(isa='XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))

common = dict(SWIFT_VERSION='5.0', IPHONEOS_DEPLOYMENT_TARGET='16.0', SDKROOT='iphoneos',
              TARGETED_DEVICE_FAMILY='1', CLANG_ENABLE_MODULES='YES', CODE_SIGN_STYLE='Automatic',
              GENERATE_INFOPLIST_FILE='YES', MARKETING_VERSION='1.6.6', CURRENT_PROJECT_VERSION='21',
              SWIFT_STRICT_CONCURRENCY='targeted', SUPPORTED_PLATFORMS='iphoneos iphonesimulator')
targets, groups, products = [], [], []
for name, folder, product_type in [
    ('JMDownloader', 'JMDownloader', 'application'),
    ('JMDownloaderTests', 'Tests', 'bundle.unit-test'),
    ('JMDownloaderUITests', 'UITests', 'bundle.ui-testing')]:
    files, sources, resources = [], [], []
    for file in sorted((ROOT / folder).glob('*.swift')):
        path = file.relative_to(ROOT).as_posix()
        file_id = ref(path, 'sourcecode.swift'); files.append(file_id)
        sources.append(add('build:' + path, dict(isa='PBXBuildFile', fileRef=file_id)))
    settings = dict(common, PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='app.jmdownloader.' + name.lower())
    if name == 'JMDownloader':
        asset = ref('JMDownloader/Assets.xcassets', 'folder.assetcatalog'); files.append(asset)
        resources.append(add('build:assets', dict(isa='PBXBuildFile', fileRef=asset)))
        notice = ref('THIRD_PARTY_NOTICES.md', 'text'); files.append(notice)
        resources.append(add('build:notice', dict(isa='PBXBuildFile', fileRef=notice)))
        settings.update(INFOPLIST_FILE='JMDownloader/Info.plist', GENERATE_INFOPLIST_FILE='NO',
                        ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',
                        ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES=['IconBlue', 'IconMono', 'IconPink', 'IconGreen'],
                        ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS='YES',
                        LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks'])
    elif name == 'JMDownloaderTests':
        settings.update(TEST_HOST='$(BUILT_PRODUCTS_DIR)/JMDownloader.app/JMDownloader', BUNDLE_LOADER='$(TEST_HOST)')
    else:
        settings.update(TEST_TARGET_NAME='JMDownloader')
    phases = []
    for phase, entries in [('Sources', sources), ('Frameworks', []), ('Resources', resources)]:
        phases.append(add(name + phase, dict(isa='PBX' + phase + 'BuildPhase', buildActionMask='2147483647', files=entries, runOnlyForDeploymentPostprocessing='0')))
    suffix = '.app' if product_type == 'application' else '.xctest'
    product = add(name + 'product', dict(isa='PBXFileReference', explicitFileType='wrapper.application' if suffix == '.app' else 'wrapper.cfbundle', path=name + suffix, sourceTree='BUILT_PRODUCTS_DIR'))
    products.append(product)
    dependencies = []
    if name != 'JMDownloader':
        proxy = add(name + 'proxy', dict(isa='PBXContainerItemProxy', containerPortal=ident('project'), proxyType='1', remoteGlobalIDString=ident('JMDownloadertarget'), remoteInfo='JMDownloader'))
        dependencies.append(add(name + 'dependency', dict(isa='PBXTargetDependency', target=ident('JMDownloadertarget'), targetProxy=proxy)))
    target = add(name + 'target', dict(isa='PBXNativeTarget', name=name, productName=name,
                 productType='com.apple.product-type.' + product_type, productReference=product,
                 buildConfigurationList=configs(name, settings), buildPhases=phases, buildRules=[], dependencies=dependencies))
    targets.append(target)
    groups.append(add(name + 'group', dict(isa='PBXGroup', name=name, children=files, sourceTree='<group>')))
products_group = add('products', dict(isa='PBXGroup', name='Products', children=products, sourceTree='<group>'))
main = add('main', dict(isa='PBXGroup', children=groups + [products_group], sourceTree='<group>'))
project = add('project', dict(isa='PBXProject', attributes={'LastUpgradeCheck': '2600', 'BuildIndependentTargetsInParallel': 'YES'},
    buildConfigurationList=configs('project', {}), compatibilityVersion='Xcode 14.0', developmentRegion='en',
    knownRegions=['en', 'zh-Hans', 'Base'], mainGroup=main, productRefGroup=products_group, projectDirPath='', projectRoot='', targets=targets))

def quote(value):
    value = str(value)
    if value and all(c.isalnum() or c in '._/' for c in value): return value
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
def encode(value, depth=0):
    if isinstance(value, dict):
        return '{\n' + '\n'.join('\t' * (depth + 1) + quote(k) + ' = ' + encode(v, depth + 1) + ';' for k, v in value.items()) + '\n' + '\t' * depth + '}'
    if isinstance(value, list): return '(' + ', '.join(encode(v, depth) for v in value) + (',' if value else '') + ')'
    return quote(value)
directory = ROOT / 'JMDownloader.xcodeproj'
directory.mkdir(exist_ok=True)
(directory / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + encode(dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=project)), encoding='utf-8')
scheme_dir = directory / 'xcshareddata/xcschemes'; scheme_dir.mkdir(parents=True, exist_ok=True)
def build_ref(name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name + "target")}" BuildableName="{name}{".app" if name == "JMDownloader" else ".xctest"}" BlueprintName="{name}" ReferencedContainer="container:JMDownloader.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{build_ref('JMDownloader')}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
<TestableReference skipped="NO">{build_ref('JMDownloaderTests')}</TestableReference>
<TestableReference skipped="NO">{build_ref('JMDownloaderUITests')}</TestableReference>
</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref('JMDownloader')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref('JMDownloader')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(scheme_dir / 'JMDownloader.xcscheme').write_text(scheme, encoding='utf-8')
info = dict(CFBundleDisplayName='JM downloader', CFBundleName='JMDownloader', CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',
    CFBundleExecutable='$(EXECUTABLE_NAME)', CFBundlePackageType='APPL', CFBundleShortVersionString='$(MARKETING_VERSION)',
    CFBundleVersion='$(CURRENT_PROJECT_VERSION)', LSRequiresIPhoneOS=True, UILaunchScreen={},
    UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False},
    UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
    UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True,
    UIBackgroundModes=['processing'],
    BGTaskSchedulerPermittedIdentifiers=['$(PRODUCT_BUNDLE_IDENTIFIER).processing'],
    NSLocalNetworkUsageDescription='用于连接你在账号设置中指定的局域网代理服务器。',
    NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
with (ROOT / 'JMDownloader/Info.plist').open('wb') as f: plistlib.dump(info, f)
print('Generated Xcode project and Info.plist')
