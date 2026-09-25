"""Generate the dependency-free Xcode project; no XcodeGen/Ruby packages required."""
from pathlib import Path
import hashlib, json, plistlib, shutil
root=Path(__file__).resolve().parent
assets=root/'YourDartClub/Resources/Assets.xcassets'
for folder in [assets,assets/'AppIcon.appiconset',assets/'Brand.imageset']: folder.mkdir(parents=True,exist_ok=True)
shutil.copyfile(root.parent/'public_html/images/yourdartclub-app-icon-1024.png',assets/'AppIcon.appiconset/Icon.png')
shutil.copyfile(root.parent/'public_html/images/yourdartclub-app-icon-1024.png',assets/'Brand.imageset/Brand.png')
(assets/'Wordmark.imageset').mkdir(exist_ok=True)
shutil.copyfile(root.parent/'public_html/images/yourdartclub-logo.png',assets/'Wordmark.imageset/Wordmark.png')
(assets/'Wordmark.imageset/Contents.json').write_text(json.dumps({'images':[{'filename':'Wordmark.png','idiom':'universal'}],'info':{'author':'xcode','version':1}}))
(assets/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}}))
(assets/'AppIcon.appiconset/Contents.json').write_text(json.dumps({'images':[{'filename':'Icon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}}))
(assets/'Brand.imageset/Contents.json').write_text(json.dumps({'images':[{'filename':'Brand.png','idiom':'universal'}],'info':{'author':'xcode','version':1}}))
info={'CFBundleDisplayName':'YourDartClub','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleName':'$(PRODUCT_NAME)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UISupportedInterfaceOrientations~ipad':['UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UIRequiresFullScreen':False,'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False}}
for mode in ['Debug','Release']:
    output=dict(info)
    (root/f'YourDartClub/Info-{mode}.plist').write_bytes(plistlib.dumps(output))
objects={}
def ident(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def obj(key,value): objects[ident(key)]=value;return ident(key)
def ref(path,typ): return obj(path,{'isa':'PBXFileReference','lastKnownFileType':typ,'path':path,'sourceTree':'<group>'})
sourcepaths=sorted([str(p.relative_to(root)) for p in (root/'YourDartClub/App').glob('*.swift')]+[str(p.relative_to(root)) for p in (root/'YourDartClub/Core').glob('*.swift')])
refs=[ref(p,'sourcecode.swift') for p in sourcepaths]
resources=[ref('YourDartClub/Resources/Assets.xcassets','folder.assetcatalog')]
langs=[]
for lang in ['nl','en','fr','de']:
    r=ref(f'YourDartClub/Resources/{lang}.lproj/Localizable.strings','text.plist.strings');objects[r]['name']=lang; langs.append(r)
resources.append(obj('localization',{'isa':'PBXVariantGroup','children':langs,'name':'Localizable.strings','sourceTree':'<group>'}))
product=obj('product',{'isa':'PBXFileReference','explicitFileType':'wrapper.application','path':'YourDartClub.app','sourceTree':'BUILT_PRODUCTS_DIR'})
main=obj('main',{'isa':'PBXGroup','children':refs+resources+[product],'sourceTree':'<group>'})
def phase(name,kind,files):return obj(name,{'isa':kind,'buildActionMask':'2147483647','files':[obj('build'+f,{'isa':'PBXBuildFile','fileRef':f}) for f in files],'runOnlyForDeploymentPostprocessing':'0'})
phases=[phase('sources','PBXSourcesBuildPhase',refs),phase('resources','PBXResourcesBuildPhase',resources),phase('frameworks','PBXFrameworksBuildPhase',[])]
def configs(name,target=False):
    configs=[]
    for mode in ['Debug','Release']:
        settings={'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O'}
        if target: settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'com.yourdartclub.iphone','PRODUCT_NAME':'YourDartClub','TARGETED_DEVICE_FAMILY':'1,2','INFOPLIST_FILE':f'YourDartClub/Info-{mode}.plist','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','CODE_SIGN_STYLE':'Automatic','OTHER_LDFLAGS':['$(inherited)','-lsqlite3'],'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else ''})
        configs.append(obj(name+mode,{'isa':'XCBuildConfiguration','buildSettings':settings,'name':mode}))
    return obj(name,{'isa':'XCConfigurationList','buildConfigurations':configs,'defaultConfigurationIsVisible':'0','defaultConfigurationName':'Release'})
target=obj('target',{'isa':'PBXNativeTarget','buildConfigurationList':configs('targetconfigs',True),'buildPhases':phases,'buildRules':[],'dependencies':[],'name':'YourDartClub','productName':'YourDartClub','productReference':product,'productType':'com.apple.product-type.application'})
project=obj('project',{'isa':'PBXProject','attributes':{'LastUpgradeCheck':'1620'},'buildConfigurationList':configs('projectconfigs'),'compatibilityVersion':'Xcode 14.0','developmentRegion':'nl','hasScannedForEncodings':'0','knownRegions':['nl','en','fr','de','Base'],'mainGroup':main,'projectDirPath':'','projectRoot':'','targets':[target]})
def fmt(v):
    if isinstance(v,dict):return '{ '+ ' '.join(f'{k} = {fmt(x)};' for k,x in v.items())+' }'
    if isinstance(v,list):return '('+','.join(fmt(x) for x in v)+')'
    return json.dumps(v)
(root/'YourDartClub.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n'+fmt({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project}))
(root/'YourDartClub.xcodeproj/xcshareddata/xcschemes/YourDartClub.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1620" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="YourDartClub.app" BlueprintName="YourDartClub" ReferencedContainer="container:YourDartClub.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="YourDartClub.app" BlueprintName="YourDartClub" ReferencedContainer="container:YourDartClub.xcodeproj"/></BuildableProductRunnable></LaunchAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
