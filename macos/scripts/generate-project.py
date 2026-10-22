#!/usr/bin/env python3
"""Generate the dependency-free Xcode project from the checked-in Swift sources."""
from pathlib import Path
import hashlib
import subprocess

base = Path(__file__).resolve().parents[1]
project = base / 'GUINVM.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

def obj(name, body):
    objects[uid(name)] = body
    return uid(name)

def refs(names):
    return '(' + ', '.join(uid(n) for n in names) + ',)'

def settings(values):
    return '{ ' + ' '.join(f'{k} = {quote(v)};' for k, v in values.items()) + ' }'

resources = [('nvm.sh', '../nvm.sh', 'text.script.sh'), ('node-semver', '../auto-switch/vendor/node-semver', 'folder'), ('release-schedule.json', '../desktop/server/release-schedule.json', 'text.json'), ('LICENSE.md', '../LICENSE.md', 'text')]
for name, path, kind in resources:
    obj('resource:' + name, f'{{isa = PBXFileReference; lastKnownFileType = {quote(kind)}; path = {quote(path)}; sourceTree = SOURCE_ROOT; }}')

targets = [('Core', 'GUINVMCore', 'com.apple.product-type.library.static', 'libGUINVMCore.a', 'archive.ar'), ('App', 'GUINVM', 'com.apple.product-type.application', 'gui-nvm.app', 'wrapper.application'), ('Tests', 'GUINVMTests', 'com.apple.product-type.bundle.unit-test', 'GUINVMTests.xctest', 'wrapper.cfbundle')]
if (base / 'UITests').exists():
    targets.append(('UITests', 'GUINVMUITests', 'com.apple.product-type.bundle.ui-testing', 'GUINVMUITests.xctest', 'wrapper.cfbundle'))
groups = []
for folder, target, product_type, product, kind in targets:
    sources = sorted((base / folder).glob('*.swift'))
    children = []
    builds = []
    for path in sources:
        key = 'source:' + str(path.relative_to(base))
        obj(key, f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path.name)}; sourceTree = "<group>"; }}')
        obj('build:' + key, f'{{isa = PBXBuildFile; fileRef = {uid(key)}; }}')
        children.append(key); builds.append('build:' + key)
    obj('group:' + folder, f'{{isa = PBXGroup; children = {refs(children)}; path = {quote(folder)}; sourceTree = "<group>"; }}')
    groups.append('group:' + folder)
    obj('product:' + folder, f'{{isa = PBXFileReference; explicitFileType = {quote(kind)}; includeInIndex = 0; path = {quote(product)}; sourceTree = BUILT_PRODUCTS_DIR; }}')
    obj('sources:' + folder, f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(builds)}; runOnlyForDeploymentPostprocessing = 0; }}')
    resource_builds = []
    if folder in ('App', 'Tests'):
        for name, _, _ in resources:
            key = 'resourcebuild:' + folder + name
            obj(key, f'{{isa = PBXBuildFile; fileRef = {uid("resource:" + name)}; }}')
            resource_builds.append(key)
    obj('resources:' + folder, f'{{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {refs(resource_builds)}; runOnlyForDeploymentPostprocessing = 0; }}')
    libs = []
    deps = []
    if folder in ('App', 'Tests'):
        obj('link:' + folder, f'{{isa = PBXBuildFile; fileRef = {uid("product:Core")}; }}')
        libs.append('link:' + folder)
        obj('proxy:' + folder, f'{{isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target:Core")}; remoteInfo = GUINVMCore; }}')
        obj('dependency:' + folder, f'{{isa = PBXTargetDependency; target = {uid("target:Core")}; targetProxy = {uid("proxy:" + folder)}; }}')
        deps.append('dependency:' + folder)
    if folder == 'UITests':
        obj('proxy:' + folder, f'{{isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target:App")}; remoteInfo = GUINVM; }}')
        obj('dependency:' + folder, f'{{isa = PBXTargetDependency; target = {uid("target:App")}; targetProxy = {uid("proxy:" + folder)}; }}')
        deps.append('dependency:' + folder)
    obj('frameworks:' + folder, f'{{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs(libs)}; runOnlyForDeploymentPostprocessing = 0; }}')
    for config in ('Debug', 'Release'):
        values = {'PRODUCT_NAME': 'gui-nvm' if folder == 'App' else target, 'PRODUCT_MODULE_NAME': target, 'PRODUCT_BUNDLE_IDENTIFIER': 'io.github.shawncai.gui-nvm' + ('.' + folder.lower() if folder != 'App' else ''), 'SWIFT_VERSION': '5.0', 'SWIFT_STRICT_CONCURRENCY': 'targeted', 'MACOSX_DEPLOYMENT_TARGET': '14.0', 'ARCHS': 'arm64', 'SUPPORTED_PLATFORMS': 'macosx', 'SDKROOT': 'macosx', 'CODE_SIGN_STYLE': 'Manual', 'CODE_SIGN_IDENTITY': '-', 'DEVELOPMENT_TEAM': '', 'ENABLE_HARDENED_RUNTIME': 'YES', 'ENABLE_APP_SANDBOX': 'NO', 'MARKETING_VERSION': '0.1.0', 'CURRENT_PROJECT_VERSION': '1', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym', 'ENABLE_TESTABILITY': 'YES' if config == 'Debug' else 'NO', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if config == 'Debug' else '', 'GENERATE_INFOPLIST_FILE': 'YES', 'SWIFT_EMIT_LOC_STRINGS': 'NO', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks', 'SWIFT_INCLUDE_PATHS': '$(inherited) $(BUILT_PRODUCTS_DIR)', 'COMBINE_HIDPI_IMAGES': 'YES'}
        if folder == 'Core':
            values.update({'SKIP_INSTALL': 'YES', 'DEFINES_MODULE': 'YES', 'SWIFT_INSTALL_OBJC_HEADER': 'NO', 'MACH_O_TYPE': 'staticlib'})
        if folder == 'App':
            values.update({'INFOPLIST_KEY_CFBundleDisplayName': 'gui-nvm', 'INFOPLIST_KEY_LSApplicationCategoryType': 'public.app-category.developer-tools', 'INFOPLIST_KEY_NSPrincipalClass': 'NSApplication', 'INFOPLIST_KEY_NSHumanReadableCopyright': 'gui-nvm contributors', 'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor', 'INFOPLIST_KEY_NSAccentColorName': 'AccentColor'})
        if folder == 'UITests':
            values['TEST_TARGET_NAME'] = 'GUINVM'
        obj('config:' + folder + config, '{isa = XCBuildConfiguration; buildSettings = ' + settings(values) + '; name = ' + config + '; }')
    obj('configs:' + folder, f'{{isa = XCConfigurationList; buildConfigurations = {refs(["config:" + folder + c for c in ("Debug", "Release")])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
    obj('target:' + folder, f'{{isa = PBXNativeTarget; buildConfigurationList = {uid("configs:" + folder)}; buildPhases = {refs(["sources:" + folder, "frameworks:" + folder, "resources:" + folder])}; buildRules = (); dependencies = {refs(deps)}; name = {target}; productName = {quote(product)}; productReference = {uid("product:" + folder)}; productType = {quote(product_type)}; }}')

# Optional application asset catalog.
if (base / 'App/Assets.xcassets').exists():
    obj('assets', '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = App/Assets.xcassets; sourceTree = SOURCE_ROOT; }')
    obj('assetsbuild', f'{{isa = PBXBuildFile; fileRef = {uid("assets")}; }}')
    body = objects[uid('resources:App')]
    objects[uid('resources:App')] = body.replace('files = (', 'files = (' + uid('assetsbuild') + ', ')
    groups.append('assets')
obj('group:Resources', f'{{isa = PBXGroup; children = {refs(["resource:" + n for n, _, _ in resources])}; name = Resources; sourceTree = "<group>"; }}')
obj('group:Products', f'{{isa = PBXGroup; children = {refs(["product:" + f for f, *_ in targets])}; name = Products; sourceTree = "<group>"; }}')
obj('group:Root', f'{{isa = PBXGroup; children = {refs(groups + ["group:Resources", "group:Products"])}; sourceTree = "<group>"; }}')
for config in ('Debug', 'Release'):
    obj('config:Project' + config, '{isa = XCBuildConfiguration; buildSettings = { CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; SWIFT_VERSION = 5.0; }; name = ' + config + '; }')
obj('configs:Project', f'{{isa = XCConfigurationList; buildConfigurations = {refs(["config:ProjectDebug", "config:ProjectRelease"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
obj('project', f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; }}; buildConfigurationList = {uid("configs:Project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = "zh-Hans"; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base); mainGroup = {uid("group:Root")}; productRefGroup = {uid("group:Products")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["target:" + f for f, *_ in targets])}; }}')
text = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
text += '\n'.join(f'{key} = {value};' for key, value in objects.items())
text += '\n}; rootObject = ' + uid('project') + '; }\n'
# Empty lists need () instead of (,).
(project / 'project.pbxproj').write_text(text.replace('(,)', '()'))
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
def reference(folder, name):
    product = next(p for f, _, _, p, _ in targets if f == folder)
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target:" + folder)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:GUINVM.xcodeproj"/>'
entries = ""
for folder, name, *_ in targets:
    if folder not in ("App", "Tests", "UITests"):
        continue
    run = "YES" if folder == "App" else "NO"
    entries += f'<BuildActionEntry buildForTesting="YES" buildForRunning="{run}" buildForProfiling="{run}" buildForArchiving="{run}" buildForAnalyzing="{run}">{reference(folder,name)}</BuildActionEntry>'
tests = ''.join(f'<TestableReference skipped="NO">{reference(f,n)}</TestableReference>' for f,n,*_ in targets if f in ('Tests','UITests'))
(schemes / 'GUINVM.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>{entries}</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests}</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('App','GUINVM')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('App','GUINVM')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
subprocess.run(['/usr/sbin/dot_clean', './'], cwd=base.parent, check=True)
print('Generated macos/GUINVM.xcodeproj')
