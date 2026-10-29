"""Package a verified iPhoneOS archive. Never substitutes a simulator app."""
from pathlib import Path
import hashlib,json,plistlib,re,shutil,subprocess

root=Path(__file__).resolve().parent.parent
build=root/'build'
app=build/'Device.xcarchive/Products/Applications/ResourceFinder.app'
with (app/'Info.plist').open('rb') as stream:
    info=plistlib.load(stream)
assert info['CFBundleIdentifier']=='com.resourcefinder.ios', 'Unexpected application bundle'
assert info.get('DTPlatformName')=='iphoneos', 'An iPhoneOS archive is required'
assert 'iPhoneOS' in info.get('CFBundleSupportedPlatforms',[]), 'Simulator app cannot become a device IPA'
version=info['CFBundleShortVersionString']
assert re.fullmatch(r'\d+\.\d+\.\d+',version), 'Invalid version'
executable=app/info['CFBundleExecutable']
architectures=subprocess.check_output(['xcrun','lipo','-archs',str(executable)],text=True).split()
assert 'arm64' in architectures, 'Device executable must include arm64'
platform=subprocess.check_output(['xcrun','vtool','-show-build',str(executable)],text=True)
assert re.search(r'platform\s+IOS\s',platform) and 'IOSSIMULATOR' not in platform, 'Wrong Mach-O platform'
assert not (app/'embedded.mobileprovision').exists(), 'Unsigned package must not include a stale profile'
staging=build/'UnsignedPackage'
if staging.exists():shutil.rmtree(staging)
payload=staging/'Payload';payload.mkdir(parents=True)
shutil.copytree(app,payload/app.name,symlinks=True)
name=f'Resource-Finder-iOS-{version}-Unsigned'
ipa=build/(name+'.ipa')
if ipa.exists():ipa.unlink()
subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(payload),str(ipa)],check=True)
digest=hashlib.sha256(ipa.read_bytes()).hexdigest()
(build/(name+'.sha256')).write_text(f'{digest}  {ipa.name}\n')
(build/'device-package.json').write_text(json.dumps({'version':version,'bundleID':info['CFBundleIdentifier'],'platform':'iPhoneOS','architectures':architectures,'signed':False,'requiresResigning':True,'package':ipa.name,'sha256':digest},indent=2)+'\n')
print(json.dumps({'package':ipa.name,'signed':False,'requiresResigning':True,'sha256':digest}))
