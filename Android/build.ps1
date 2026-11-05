param(
    [string]$Sdk = "$env:LOCALAPPDATA/Android/Sdk",
    [string]$Java = 'C:/Program Files/Android/Android Studio/jbr',
    [string]$SigningStore = ''
)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$bt=Join-Path $Sdk 'build-tools/36.0.0'
$jar=Join-Path $Sdk 'platforms/android-35/android.jar'
$build=Join-Path $root 'build'
if(-not $SigningStore){$SigningStore=Join-Path $root 'build-private/svanar.keystore'}
$env:JAVA_HOME=$Java
$env:PATH=(Join-Path $Java 'bin')+';'+$env:PATH
function Run([string]$Exe,[string[]]$Arguments){ & $Exe @Arguments; if($LASTEXITCODE -ne 0){throw "Command failed: $Exe ($LASTEXITCODE)"} }
foreach($p in @($jar,(Join-Path $bt 'aapt2.exe'),(Join-Path $Java 'bin/javac.exe'))){if(-not(Test-Path -LiteralPath $p)){throw "Missing build dependency: $p"}}
New-Item -ItemType Directory -Force "$build/classes","$build/tests","$build/dex","$build/generated",(Split-Path $SigningStore) | Out-Null
$sources=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.java' -Recurse | ForEach-Object FullName)
Run "$Java/bin/javac.exe" @('-encoding','UTF-8','-d',"$build/tests","$root/src/io/local/svanarcontrol/Protocol.java","$root/src/io/local/svanarcontrol/Presets.java","$root/src/io/local/svanarcontrol/Extras.java","$root/src/io/local/svanarcontrol/TouchMap.java","$root/tests/ProtocolTest.java")
Run "$Java/bin/java.exe" @('-cp',"$build/tests",'io.local.svanarcontrol.ProtocolTest')
Run "$bt/aapt2.exe" @('compile','--dir',"$root/res",'-o',"$build/resources.zip")
Run "$bt/aapt2.exe" @('link','-o',"$build/resources.apk",'-I',$jar,'--manifest',"$root/AndroidManifest.xml",'--java',"$build/generated","$build/resources.zip")
Run "$Java/bin/javac.exe" (@('-encoding','UTF-8','--release','8','-classpath',$jar,'-d',"$build/classes")+$sources)
Run "$Java/bin/jar.exe" @('--create','--file',"$build/classes.jar",'-C',"$build/classes",'.')
Run "$bt/d8.bat" @('--release','--min-api','26','--lib',$jar,'--output',"$build/dex","$build/classes.jar")
Copy-Item -LiteralPath "$build/resources.apk" -Destination "$build/unsigned.apk" -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::Open("$build/unsigned.apk",[IO.Compression.ZipArchiveMode]::Update)
try{[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,"$build/dex/classes.dex",'classes.dex') | Out-Null}finally{$zip.Dispose()}
Run "$bt/zipalign.exe" @('-f','-p','4',"$build/unsigned.apk","$build/aligned.apk")
if(-not(Test-Path -LiteralPath $SigningStore)){
    Run "$Java/bin/keytool.exe" @('-genkeypair','-keystore',$SigningStore,'-storepass','android','-keypass','android','-alias','svanar','-dname','CN=Svanar Control Local Build','-keyalg','RSA','-keysize','3072','-validity','10000','-storetype','PKCS12')
}
Run "$bt/apksigner.bat" @('sign','--ks',$SigningStore,'--ks-pass','pass:android','--key-pass','pass:android','--ks-key-alias','svanar','--out',"$root/SvanarControl-Android.apk","$build/aligned.apk")
Run "$bt/apksigner.bat" @('verify','--verbose',"$root/SvanarControl-Android.apk")
Write-Host "Built: $root/SvanarControl-Android.apk"
